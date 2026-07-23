# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentService do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:service) { described_class.new(seller:, pundit_user:) }
  # The agent runs on Claude via Ai::AnthropicClient; stub it so these stay fast unit tests of the
  # tool-dispatch + propose/confirm logic. The client returns Ai::AnthropicClient::Result structs.
  let(:client) { instance_double(Ai::AnthropicClient) }
  # The service reaches the real v2 API through StoreAgentApiClient; stub it too (the executor spec
  # covers the real API path).
  let(:api_client) { instance_double(Ai::StoreAgentApiClient) }

  before do
    allow(Ai::AnthropicClient).to receive(:new).and_return(client)
    allow(Ai::StoreAgentApiClient).to receive(:new).and_return(api_client)
  end

  # A model turn with plain assistant text and no tool use.
  def text_result(text)
    Ai::AnthropicClient::Result.new(text:, tool_uses: [], stop_reason: "end_turn")
  end

  # A model turn that asks to use a tool (Anthropic tool_use block).
  def tool_result(name, input, id: "toolu_1", text: "")
    Ai::AnthropicClient::Result.new(text:, tool_uses: [{ id:, name:, input: }], stop_reason: "tool_use")
  end

  # Find the tool_result block the service fed back into the conversation for the most recent tool
  # call, by inspecting the messages passed to the follow-up client.messages call.
  def captured_tool_result(args)
    tool_msg = args[:messages].reverse.find { |m| m[:role] == "user" && m[:content].is_a?(Array) && m[:content].any? { |c| c[:type] == "tool_result" } }
    return nil unless tool_msg

    block = tool_msg[:content].find { |c| c[:type] == "tool_result" }
    JSON.parse(block[:content])
  end

  describe "#respond" do
    it "requires the conversation to end with a user message" do
      expect { service.respond(messages: [{ role: "assistant", content: "hi" }]) }
        .to raise_error(described_class::Error)
    end

    it "returns the model's reply when no tools are called" do
      allow(client).to receive(:messages).and_return(text_result("You have 3 products."))

      result = service.respond(messages: [{ role: "user", content: "How many products do I have?" }])

      expect(result[:reply]).to eq("You have 3 products.")
      expect(result[:proposed_action]).to be_nil
    end

    it "drops a leading assistant greeting so Anthropic gets a user-first conversation" do
      captured = nil
      allow(client).to receive(:messages) do |args|
        captured = args
        text_result("ok")
      end

      # The web chat always opens with the canned assistant greeting before the first user message;
      # Anthropic rejects a conversation that doesn't start with a user message.
      service.respond(messages: [
                        { role: "assistant", content: "Hi! I'm your Gumroad store assistant." },
                        { role: "user", content: "How are my sales?" },
                      ])

      expect(captured[:messages].first[:role]).to eq("user")
      expect(captured[:messages].map { |m| m[:role] }).to eq(["user"])
    end

    it "passes the system prompt and tools to the model on the first call" do
      captured = nil
      allow(client).to receive(:messages) do |args|
        captured = args
        text_result("ok")
      end

      service.respond(messages: [{ role: "user", content: "hi" }])

      expect(captured[:system]).to include("Gumroad's store assistant")
      expect(captured[:tools].map { |t| t[:name] }).to contain_exactly("api_read", "api_write")
      # System prompt is NOT echoed into the messages array (it's Anthropic's top-level param).
      expect(captured[:messages].none? { |m| m[:role] == "system" }).to be(true)
    end

    describe "api_read" do
      it "runs a read endpoint against the API and feeds the result back to the model" do
        expect(api_client).to receive(:get).with("/products", {}).and_return(
          { "success" => true, "products" => [{ "id" => "p1", "name" => "Cool Ebook", "formatted_price" => "$9.99", "published" => true }], "http_status" => 200 },
        )
        allow(client).to receive(:messages).and_return(
          tool_result("api_read", { "endpoint" => "list_products" }),
          text_result("Your product Cool Ebook is $9.99."),
        )

        result = service.respond(messages: [{ role: "user", content: "List my products" }])

        expect(result[:reply]).to eq("Your product Cool Ebook is $9.99.")
        expect(client).to have_received(:messages).twice
        # The product is surfaced as a display object for the chat to render inline as a card.
        expect(result[:objects]).to include(include(type: "product", title: "Cool Ebook"))
      end

      it "expands path params into the endpoint path" do
        expect(api_client).to receive(:get).with("/products/abc123", {}).and_return({ "success" => true, "http_status" => 200 })
        allow(client).to receive(:messages).and_return(
          tool_result("api_read", { "endpoint" => "get_product", "path_params" => { "id" => "abc123" } }),
          text_result("Here is that product."),
        )

        service.respond(messages: [{ role: "user", content: "show product abc123" }])
      end

      # Regression: gumroad-private#1168. list_products is paginated (10 per page) but the agent
      # could never reach past page one, and the raw next_page_key had to reach the model so it
      # knows more pages exist. A seller with >10 products would otherwise get silently incomplete
      # catalog-wide answers.
      it "passes page_key through to the API and feeds next_page_key back to the model" do
        expect(api_client).to receive(:get).with("/products", { "page_key" => "key-1" }).and_return(
          { "success" => true, "products" => [{ "id" => "p11", "name" => "Older Product" }], "next_page_key" => "key-2", "http_status" => 200 },
        )
        captured = nil
        first = true
        allow(client).to receive(:messages) do |args|
          captured = captured_tool_result(args) unless first
          if first
            first = false
            tool_result("api_read", { "endpoint" => "list_products", "params" => { "page_key" => "key-1" } })
          else
            text_result("Here is the next page.")
          end
        end

        service.respond(messages: [{ role: "user", content: "show the rest of my products" }])

        expect(captured).to include("next_page_key" => "key-2")
      end

      # Regression for the review finding on gumroad-private#1168's fix: the pagination prompt rule
      # is useless if the tool-iteration cap stops the walk first. With the old cap of 5, a seller
      # whose list spanned more than ~4 pages got the generic "couldn't finish" fallback on exactly
      # the "all of X" tasks pagination exists for. This walks 8 pages and still gets a real answer.
      it "lets the model walk well past five pages before the tool-iteration cap" do
        pages = 8
        call_count = 0
        allow(api_client).to receive(:get) do |_path, _params|
          call_count += 1
          key = call_count < pages ? "key-#{call_count}" : nil
          { "success" => true, "products" => [{ "id" => "p#{call_count}", "name" => "Product #{call_count}" }], "next_page_key" => key, "http_status" => 200 }.compact
        end
        turns = 0
        allow(client).to receive(:messages) do
          turns += 1
          if turns <= pages
            input = turns == 1 ? { "endpoint" => "list_products" } : { "endpoint" => "list_products", "params" => { "page_key" => "key-#{turns - 1}" } }
            tool_result("api_read", input)
          else
            text_result("You have #{pages} pages of products; here's the full list.")
          end
        end

        result = service.respond(messages: [{ role: "user", content: "list all my products" }])

        expect(call_count).to eq(pages)
        expect(result[:reply]).to include("full list")
        # The reply is the model's real answer, not the iteration-cap fallback.
        expect(result[:reply]).not_to match(/couldn't finish/i)
      end

      it "teaches the model to paginate list reads in the system prompt" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        expect(captured[:system]).to include("next_page_key")
        expect(captured[:system]).to include("imply you checked items you did not actually fetch")
      end

      # Regression for gumroad-private#984: the agent invented dashboard settings screens
      # ("Settings > Profile pickers") that don't exist, admitted it was "guessing at the UI",
      # and looped on "confirm the change" without ever staging one. The system prompt must
      # tell the model what is actually possible: no dashboard visibility, no self-serve
      # appearance settings, custom HTML is the only appearance surface, a brand-new page must
      # carry the whole storefront, and "prepared for confirmation" claims require a real
      # api_write in the same reply.
      it "teaches the model what is possible: no dashboard visibility, no appearance settings, no phantom confirmations" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        expect(captured[:system]).to include("cannot see the creator's dashboard")
        expect(captured[:system]).to include("NO self-serve settings")
        expect(captured[:system]).to include("never direct them to dashboard settings that don't exist")
        expect(captured[:system]).to include(%(<script id="gumroad-data"))
        expect(captured[:system]).to match(/never hard-code the product list/)
        expect(captured[:system]).to match(/Never publish a page that drops the creator's products/)
        expect(captured[:system]).to match(/unless\s+you actually called api_write in this same reply/)
      end

      # Follow-up to gumroad-private#984: with the rules above in place, the agent authored a
      # page whose script hunted for the creator's name in the gumroad-data JSON (data.user.name)
      # — a key that doesn't exist there — so the published header fell back to a generic "Store"
      # and the name and bio never rendered. The prompt must spell out the mechanism, not just
      # the requirement: say exactly what the injected JSON contains (and that name/bio/avatar
      # are NOT in it), point at data-gumroad-field elements as the only way to render name and
      # bio, warn that Pages::Interpolator overwrites placeholder text even when a field is
      # blank, restrict images to Gumroad-hosted urls the agent actually has, and require an
      # empty state when the store has no published products so an empty store doesn't read as
      # a broken page.
      it "spells out how a page gets the creator's name, bio, and an empty product state" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        expect(captured[:system]).to match(/does NOT contain the\s+creator's name, bio, avatar/)
        expect(captured[:system]).to include(%(data-gumroad-field="name"))
        expect(captured[:system]).to include(%(data-gumroad-field="bio"))
        expect(captured[:system]).to match(/If the products array is empty,\s+render a visible empty state/)
        expect(captured[:system]).to match(/Placeholder text you write inside\s+these elements is always overwritten/)
        expect(captured[:system]).to match(/Only include\s+an avatar, logo, or photo when you have a real Gumroad-hosted image url/)
        expect(captured[:system]).to match(/Never author an empty image slot/)
      end

      it "rejects an unknown endpoint id without calling the API" do
        expect(api_client).not_to receive(:get)
        captured = nil
        first = true
        allow(client).to receive(:messages) do |args|
          captured = captured_tool_result(args)
          if first
            first = false
            tool_result("api_read", { "endpoint" => "drop_tables" })
          else
            text_result("ok")
          end
        end

        service.respond(messages: [{ role: "user", content: "hack" }])

        expect(captured).to include("error")
      end

      it "refuses to run a WRITE endpoint through api_read (it must be confirmed)" do
        expect(api_client).not_to receive(:get)
        captured = nil
        first = true
        allow(client).to receive(:messages) do |args|
          captured = captured_tool_result(args)
          if first
            first = false
            tool_result("api_read", { "endpoint" => "refund_sale", "path_params" => { "id" => "1" } })
          else
            text_result("ok")
          end
        end

        service.respond(messages: [{ role: "user", content: "refund it now" }])

        expect(captured["error"]).to match(/confirm/i)
      end

      it "surfaces a missing path param as an error instead of raising" do
        expect(api_client).not_to receive(:get)
        captured = nil
        first = true
        allow(client).to receive(:messages) do |args|
          captured = captured_tool_result(args)
          if first
            first = false
            tool_result("api_read", { "endpoint" => "get_product" })
          else
            text_result("ok")
          end
        end

        service.respond(messages: [{ role: "user", content: "show the product" }])

        expect(captured["error"]).to match(/missing path parameter/i)
      end
    end

    describe "api_write" do
      it "returns a proposed action WITHOUT mutating or calling the API" do
        expect(api_client).not_to receive(:write)
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "create_offer_code",
                        "path_params" => { "link_id" => "prod_1" },
                        "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
                      }),
          text_result("I've prepared a 20% off code called LAUNCH for your confirmation."),
        )

        result = service.respond(messages: [{ role: "user", content: "Make a 20% off code LAUNCH" }])

        expect(result[:proposed_action]).to include(
          type: "api_write",
          params: include(
            "endpoint" => "create_offer_code",
            "path_params" => { "link_id" => "prod_1" },
            "params" => include("name" => "LAUNCH"),
          ),
        )
        expect(result[:proposed_action][:summary]).to be_present
        expect(result[:proposed_action][:fields]).to include(
          { label: "Code", value: "LAUNCH" },
          { label: "Discount", value: "20% off" },
        )
      end

      it "builds preview fields from untrusted tool values without raising on a non-scalar" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "update_product",
                        "path_params" => { "id" => "prod_1" },
                        "params" => { "price" => { "unexpected" => "object" } },
                      }),
          text_result("Prepared the change."),
        )

        result = nil
        expect { result = service.respond(messages: [{ role: "user", content: "update it" }]) }.not_to raise_error
        # The malformed value is shown (JSON-encoded), never dropped or crashed on.
        expect(result[:proposed_action][:fields]).to include({ label: "Price", value: "{\"unexpected\":\"object\"}" })
      end

      it "shows a long field value in full rather than truncating what will be applied" do
        long_description = "a" * 200
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "update_product",
                        "path_params" => { "id" => "prod_1" },
                        "params" => { "description" => long_description },
                      }),
          text_result("Prepared."),
        )

        result = service.respond(messages: [{ role: "user", content: "update the description" }])
        expect(result[:proposed_action][:fields]).to include({ label: "Description", value: long_description })
      end

      it "previews a blank money value as (blank), not $0" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "create_product",
                        "path_params" => {},
                        "params" => { "name" => "P", "price" => "" },
                      }),
          text_result("Prepared."),
        )

        result = service.respond(messages: [{ role: "user", content: "make a product with no price yet" }])
        expect(result[:proposed_action][:fields]).to include({ label: "Price", value: "(blank)" })
      end

      it "shows a non-numeric money value raw instead of coercing it to $0" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "create_product",
                        "path_params" => {},
                        "params" => { "name" => "P", "price" => "free" },
                      }),
          text_result("Prepared."),
        )

        result = service.respond(messages: [{ role: "user", content: "make it free" }])
        expect(result[:proposed_action][:fields]).to include({ label: "Price", value: "free" })
      end

      it "does not crash when a money param is a boolean" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "create_product",
                        "path_params" => {},
                        "params" => { "name" => "P", "price" => true },
                      }),
          text_result("Prepared."),
        )

        result = nil
        expect { result = service.respond(messages: [{ role: "user", content: "make a product" }]) }.not_to raise_error
        expect(result[:proposed_action][:fields]).to include({ label: "Price", value: "true" })
      end

      it "does not crash formatting a fixed discount whose amount is a non-scalar" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "create_offer_code",
                        "path_params" => { "link_id" => "prod_1" },
                        "params" => { "name" => "X", "amount_off" => { "unexpected" => "object" } },
                      }),
          text_result("Prepared."),
        )

        expect { service.respond(messages: [{ role: "user", content: "make a code" }]) }.not_to raise_error
      end

      it "keeps a body field the model set to blank visible (so a clear isn't hidden)" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "update_product",
                        "path_params" => { "id" => "prod_1" },
                        "params" => { "description" => "" },
                      }),
          text_result("Prepared."),
        )

        result = service.respond(messages: [{ role: "user", content: "clear the description" }])
        expect(result[:proposed_action][:fields]).to include({ label: "Description", value: "(blank)" })
      end

      it "rejects a READ endpoint sent to api_write (nudges to api_read)" do
        captured = nil
        first = true
        allow(client).to receive(:messages) do |args|
          captured = captured_tool_result(args)
          if first
            first = false
            tool_result("api_write", { "endpoint" => "list_products" })
          else
            text_result("ok")
          end
        end

        result = service.respond(messages: [{ role: "user", content: "change products" }])

        expect(result[:proposed_action]).to be_nil
        expect(captured["error"]).to match(/api_read/i)
      end

      it "validates path params at propose time so a missing id can't reach the executor" do
        captured = nil
        first = true
        allow(client).to receive(:messages) do |args|
          captured = captured_tool_result(args)
          if first
            first = false
            tool_result("api_write", { "endpoint" => "refund_sale", "params" => { "amount_cents" => 100 } })
          else
            text_result("ok")
          end
        end

        result = service.respond(messages: [{ role: "user", content: "refund" }])

        expect(result[:proposed_action]).to be_nil
        expect(captured["error"]).to match(/missing path parameter/i)
      end

      it "refuses to stage a body with a key the endpoint does not declare and names the accepted keys" do
        # The doom-loop case from gumroad-private#953: the model sends `price_cents` (an internal
        # column name) where create_product declares `price`. Staging it would create a priceless
        # product that fails deep in the API; instead the tool_result must correct the model in the
        # same turn by naming the unknown key and the keys the endpoint actually accepts.
        captured = nil
        first = true
        allow(client).to receive(:messages) do |args|
          captured = captured_tool_result(args)
          if first
            first = false
            tool_result("api_write", { "endpoint" => "create_product", "params" => { "name" => "X", "price_cents" => 9900 } })
          else
            text_result("ok")
          end
        end

        result = service.respond(messages: [{ role: "user", content: "make a $99 product" }])

        expect(result[:proposed_action]).to be_nil
        expect(captured["error"]).to include("price_cents")
        expect(captured["error"]).to include("name, price, description, custom_permalink, price_currency_type, max_purchase_count")
      end
    end

    context "when the model proposes more than one write in a single turn" do
      def two_write_uses
        Ai::AnthropicClient::Result.new(
          text: "",
          tool_uses: [
            { id: "toolu_a", name: "api_write", input: { "endpoint" => "create_offer_code", "path_params" => { "link_id" => "p1" }, "params" => { "name" => "FIRST", "amount_off" => 10, "offer_type" => "percent" } } },
            { id: "toolu_b", name: "api_write", input: { "endpoint" => "create_offer_code", "path_params" => { "link_id" => "p1" }, "params" => { "name" => "SECOND", "amount_off" => 50, "offer_type" => "percent" } } },
          ],
          stop_reason: "tool_use",
        )
      end

      it "stages only the first proposal and tells the model the second was dropped" do
        captured_results = []
        first = true
        allow(client).to receive(:messages) do |args|
          tool_msg = args[:messages].reverse.find { |m| m[:role] == "user" && m[:content].is_a?(Array) && m[:content].any? { |c| c[:type] == "tool_result" } }
          captured_results = tool_msg[:content].filter_map { |c| JSON.parse(c[:content]) if c[:type] == "tool_result" } if tool_msg
          if first
            first = false
            two_write_uses
          else
            text_result("I've prepared the FIRST code for your confirmation.")
          end
        end

        result = service.respond(messages: [{ role: "user", content: "make two codes" }])

        expect(result[:proposed_action]).to include(type: "api_write", params: include("params" => include("name" => "FIRST")))
        expect(captured_results.last).to include("error")
        expect(captured_results.last["error"]).to match(/one change/i)
      end
    end

    context "when the model never finishes within the tool-iteration cap" do
      it "does not claim there is a change to confirm when none was staged" do
        allow(api_client).to receive(:get).and_return({ "success" => true, "http_status" => 200 })
        allow(client).to receive(:messages).and_return(tool_result("api_read", { "endpoint" => "list_products" }))

        result = service.respond(messages: [{ role: "user", content: "loop forever" }])

        expect(result[:proposed_action]).to be_nil
        expect(result[:reply]).not_to match(/confirm/i)
      end
    end

    context "when a model turn is truncated by the max_tokens cap" do
      # A truncated turn (stop_reason "max_tokens") is incomplete no matter what it contains: a
      # cut-off text answer reads as a finished reply but isn't, and a cut-off tool call has
      # unusable arguments. The service must return the honest fallback rather than the fragment.
      def truncated_text_result(text)
        Ai::AnthropicClient::Result.new(text:, tool_uses: [], stop_reason: "max_tokens")
      end

      it "does not return a truncated text turn as if it were a complete reply" do
        allow(client).to receive(:messages).and_return(truncated_text_result("Sorry about that — let me"))

        result = service.respond(messages: [{ role: "user", content: "rewrite my whole description" }])

        expect(result[:reply]).to eq(described_class::TRUNCATED_REPLY)
        expect(result[:reply]).not_to include("Sorry about that")
        expect(result[:proposed_action]).to be_nil
      end

      it "handles a truncated tool-call turn gracefully instead of raising" do
        # The client drops a tool call whose JSON was cut off mid-stream, so the truncated turn
        # arrives here with no usable tool_uses and stop_reason "max_tokens".
        allow(client).to receive(:messages).and_return(truncated_text_result(""))

        expect do
          result = service.respond(messages: [{ role: "user", content: "update the description" }])
          expect(result[:reply]).to eq(described_class::TRUNCATED_REPLY)
        end.not_to raise_error
      end
    end

    context "when the model emits a non-hash tool input" do
      # Anthropic normally delivers tool input as a JSON object, but our client coerces a malformed
      # input to {}; the tool then falls through to its normal "endpoint is required" handling rather
      # than raising a 500.
      it "does not raise and proposes nothing" do
        allow(client).to receive(:messages).and_return(
          Ai::AnthropicClient::Result.new(text: "", tool_uses: [{ id: "toolu_1", name: "api_write", input: {} }], stop_reason: "tool_use"),
          text_result("I need a bit more detail to make that change."),
        )

        expect do
          result = service.respond(messages: [{ role: "user", content: "make a change" }])
          expect(result[:reply]).to be_present
          expect(result[:proposed_action]).to be_nil
        end.not_to change { seller.offer_codes.count }
      end
    end
  end

  describe "#respond_streaming" do
    # Stub a streaming model turn: yield each text piece to the block (as the real client streams
    # deltas), then return a Result. Subsequent calls dequeue the next scripted turn.
    def stub_stream_turns(*turns)
      queue = turns.dup
      allow(client).to receive(:stream_messages) do |_args, &on_text|
        turn = queue.shift
        Array(turn[:stream]).each { |piece| on_text&.call(piece) }
        turn[:result]
      end
    end

    def collect_events(messages)
      events = []
      result = service.respond_streaming(messages:) { |event, payload| events << [event, payload] }
      [events, result]
    end

    it "streams the reply token-by-token and then suggests follow-up prompts" do
      stub_stream_turns(stream: ["You have ", "3 products."], result: text_result("You have 3 products."))
      # The follow-up suggestions use the buffered (non-streaming) call.
      allow(client).to receive(:messages).and_return(text_result('["List my products", "Show my sales"]'))

      events, result = collect_events([{ role: "user", content: "How many products?" }])

      token_texts = events.filter_map { |event, payload| payload[:text] if event == :token }
      expect(token_texts).to eq(["You have ", "3 products."])
      expect(result[:reply]).to eq("You have 3 products.")

      suggestions_event = events.find { |event, _| event == :suggestions }
      expect(suggestions_event).to be_present
      expect(suggestions_event.last[:suggestions]).to eq(["List my products", "Show my sales"])
      expect(result[:suggestions]).to eq(["List my products", "Show my sales"])
    end

    it "invokes on_reply_complete with the finished turn before trailing events and the suggestions call" do
      stub_stream_turns(stream: ["Here are your numbers."], result: text_result("Here are your numbers."))
      order = []
      allow(client).to receive(:messages) do
        order << :suggestions_call
        text_result('["Show my sales"]')
      end

      completed_turn = nil
      on_reply_complete = lambda do |turn|
        order << :reply_complete
        completed_turn = turn
      end
      result = service.respond_streaming(messages: [{ role: "user", content: "how are sales" }], on_reply_complete:) do |event, _payload|
        order << event unless event == :token
      end

      # The finished turn reaches the hook before anything else happens — before the extra
      # suggestions LLM call and before any trailing event is written to the (possibly already
      # dead) client socket — so callers can persist it no matter what happens afterwards.
      expect(order).to eq([:reply_complete, :suggestions_call, :suggestions])
      expect(completed_turn).to eq(reply: "Here are your numbers.", proposed_action: nil, objects: [])
      expect(result[:suggestions]).to eq(["Show my sales"])
    end

    it "emits a proposed action over the stream without mutating" do
      stub_stream_turns(
        { stream: [], result: tool_result("api_write", { "endpoint" => "create_offer_code", "path_params" => { "link_id" => "p1" }, "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" } }) },
        { stream: ["I've prepared that discount for your confirmation."], result: text_result("I've prepared that discount for your confirmation.") },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))

      expect do
        events, result = collect_events([{ role: "user", content: "make a 20% code called LAUNCH" }])
        action_event = events.find { |event, _| event == :proposed_action }
        expect(action_event).to be_present
        expect(action_event.last[:proposed_action]).to include(type: "api_write")
        expect(result[:proposed_action]).to include(type: "api_write")
      end.not_to change { seller.offer_codes.count }
    end

    it "still returns a reply when the follow-up suggestion call fails" do
      stub_stream_turns(stream: ["Here are your numbers."], result: text_result("Here are your numbers."))
      allow(client).to receive(:messages).and_raise(Ai::AnthropicClient::Error, "suggestion model unavailable")

      events, result = collect_events([{ role: "user", content: "how are sales" }])

      expect(result[:reply]).to eq("Here are your numbers.")
      expect(result[:suggestions]).to eq([])
      expect(events.any? { |event, _| event == :suggestions }).to be(false)
    end

    it "parses a newline/dash suggestion list as a fallback when the model doesn't return JSON" do
      stub_stream_turns(stream: ["Done."], result: text_result("Done."))
      allow(client).to receive(:messages).and_return(text_result("- Show my best sellers\n- Email my customers\n- Create a discount"))

      _events, result = collect_events([{ role: "user", content: "help" }])

      expect(result[:suggestions]).to eq(["Show my best sellers", "Email my customers", "Create a discount"])
    end

    it "emits a reset when an intermediate tool-use turn streams preamble text, then streams the real reply" do
      # First turn: the model streams a preamble ("Let me check...") AND asks to call a read tool.
      # That preamble is not the answer, so the service must emit :reset before the final turn.
      read_turn = Ai::AnthropicClient::Result.new(
        text: "Let me check that for you.",
        tool_uses: [{ id: "toolu_1", name: "api_read", input: { "endpoint" => "list_products" } }],
        stop_reason: "tool_use",
      )
      allow(api_client).to receive(:get).and_return({ "success" => true, "products" => [], "http_status" => 200 })
      stub_stream_turns(
        { stream: ["Let me check ", "that for you."], result: read_turn },
        { stream: ["You have 3 products."], result: text_result("You have 3 products.") },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))

      events, result = collect_events([{ role: "user", content: "How many products?" }])

      event_names = events.map(&:first)
      # The preamble streamed, then a reset, then the real reply tokens.
      expect(event_names).to include(:reset)
      expect(event_names.index(:reset)).to be < event_names.rindex(:token)
      expect(result[:reply]).to eq("You have 3 products.")
    end

    it "resets any streamed fragment and streams the honest fallback when a turn hits max_tokens" do
      # The model streams part of a reply (or a tool call's preamble) and is then cut off by the
      # token cap. What streamed is incomplete, so the UI must be told to discard it and the seller
      # must get the honest fallback rather than half an answer presented as complete.
      truncated = Ai::AnthropicClient::Result.new(text: "Here's the new descri", tool_uses: [], stop_reason: "max_tokens")
      stub_stream_turns(stream: ["Here's the new descri"], result: truncated)
      allow(client).to receive(:messages).and_return(text_result("[]"))

      events, result = collect_events([{ role: "user", content: "rewrite my whole description" }])

      event_names = events.map(&:first)
      expect(event_names).to include(:reset)
      # The reset must come BEFORE the fallback token. If the order were flipped, the UI would
      # render the fallback and then immediately wipe it, leaving the seller with nothing.
      fallback_index = events.index { |event, payload| event == :token && payload[:text] == described_class::TRUNCATED_REPLY }
      expect(fallback_index).not_to be_nil
      expect(event_names.index(:reset)).to be < fallback_index
      final_tokens = events.filter_map { |event, payload| payload[:text] if event == :token }
      expect(final_tokens.last).to eq(described_class::TRUNCATED_REPLY)
      expect(result[:reply]).to eq(described_class::TRUNCATED_REPLY)
    end
  end
end
