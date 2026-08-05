# frozen_string_literal: true

require "spec_helper"
require "timeout"

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

  # A model turn with assistant text and the required typed terminal marker.
  def text_result(text, outcome: "reply_only")
    complete_turn_result(text, outcome:)
  end

  def untyped_text_result(text)
    Ai::AnthropicClient::Result.new(text:, tool_uses: [], stop_reason: "end_turn")
  end

  def complete_turn_result(text, outcome:)
    Ai::AnthropicClient::Result.new(
      text:,
      tool_uses: [{ id: "toolu_complete", name: "complete_turn", input: { "outcome" => outcome } }],
      stop_reason: "tool_use",
    )
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
      expect(captured[:tools].map { |t| t[:name] }).to contain_exactly("api_read", "api_write", "complete_turn")
      expect(captured[:system]).to include("existing Store Agent webhooks can be")
      expect(captured[:system]).to include("the Store Agent cannot create webhooks")
      expect(captured[:system]).to match(/Settings >\s+Advanced > Ping/)
      # System prompt is NOT echoed into the messages array (it's Anthropic's top-level param).
      expect(captured[:messages].none? { |m| m[:role] == "system" }).to be(true)
    end

    it "keeps trusted proposal state after truncating an assistant history message" do
      captured = nil
      allow(client).to receive(:messages) do |args|
        captured = args
        text_result("ok")
      end
      proposal_state = "the action was applied and cannot be confirmed again"

      service.respond(messages: [
                        { role: "user", content: "Earlier question" },
                        {
                          role: "assistant",
                          content: "x" * (described_class::MAX_MESSAGE_LENGTH + 100),
                          proposal_state:,
                        },
                        { role: "user", content: "What now?" },
                      ])

      assistant_message = captured[:messages].second
      expect(assistant_message.keys).to contain_exactly(:role, :content)
      expect(assistant_message[:content].length).to eq(described_class::MAX_MESSAGE_LENGTH)
      expect(assistant_message[:content]).to end_with("\n\n[Server proposal state: #{proposal_state}]")
    end

    it "sends the whole request the creator just typed, and still trims their earlier turns" do
      captured = nil
      allow(client).to receive(:messages) do |args|
        captured = args
        text_result("ok")
      end
      earlier_request = "e" * (described_class::MAX_MESSAGE_LENGTH + 500)
      current_request = "c" * (described_class::MAX_MESSAGE_LENGTH + 500)

      service.respond(messages: [
                        { role: "user", content: earlier_request },
                        { role: "assistant", content: "Done." },
                        { role: "user", content: current_request },
                      ])

      # The decoy is a user message of the SAME oversized length, so a limit applied to every user
      # message alike cannot pass this: the earlier turn must still be cut and the last one must not.
      expect(captured[:messages].first[:content].length).to eq(described_class::MAX_MESSAGE_LENGTH)
      expect(captured[:messages].last[:content]).to eq(current_request)
    end

    it "trims a current message past the current-message budget" do
      captured = nil
      allow(client).to receive(:messages) do |args|
        captured = args
        text_result("ok")
      end

      service.respond(messages: [{ role: "user", content: "c" * (described_class::MAX_CURRENT_MESSAGE_LENGTH + 100) }])

      expect(captured[:messages].last[:content].length).to eq(described_class::MAX_CURRENT_MESSAGE_LENGTH)
    end

    it "treats the last non-blank user turn as the current message when blank turns trail it" do
      captured = nil
      allow(client).to receive(:messages) do |args|
        captured = args
        text_result("ok")
      end
      current_request = "c" * (described_class::MAX_MESSAGE_LENGTH + 500)

      service.respond(messages: [
                        { role: "user", content: current_request },
                        { role: "user", content: "   " },
                      ])

      expect(captured[:messages].last[:content]).to eq(current_request)
    end

    context "when the model completes a turn" do
      it "rejects an untyped staging claim that the prose backstop does not recognize" do
        false_claim = "Your edit is waiting in the action panel. Use the button there."
        expect(described_class::STAGED_CLAIM_PATTERNS.none? { |pattern| false_claim.match?(pattern) }).to be(true)
        allow(client).to receive(:messages).and_return(
          untyped_text_result(false_claim),
          complete_turn_result("I couldn't prepare that change. Please ask me to try again.", outcome: "reply_only"),
        )

        result = service.respond(messages: [{ role: "user", content: "fix my header" }])

        expect(client).to have_received(:messages).twice
        expect(result[:reply]).not_to eq(false_claim)
        expect(result[:outcome]).to eq("reply_only")
        expect(result[:proposed_action]).to be_nil
      end

      it "uses server-owned confirmation copy for a typed proposal" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "create_offer_code",
                        "path_params" => { "link_id" => "prod_1" },
                        "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
                      }),
          complete_turn_result("The action panel is ready.", outcome: "proposal_ready"),
        )

        result = service.respond(messages: [{ role: "user", content: "Make a 20% off code" }])

        expect(result[:reply]).to eq("I prepared that change. Review it below, then confirm it when you're ready.")
        expect(result[:outcome]).to eq("proposal_ready")
        expect(result[:proposed_action]).to include(type: "api_write")
      end

      it "rejects server-owned confirmation copy when reply_only has no proposal" do
        expect(described_class::STAGED_CLAIM_PATTERNS.none? { |pattern| described_class::PROPOSAL_READY_REPLY.match?(pattern) }).to be(true)
        allow(client).to receive(:messages).and_return(
          complete_turn_result(described_class::PROPOSAL_READY_REPLY, outcome: "reply_only"),
        )

        result = service.respond(messages: [{ role: "user", content: "fix my header" }])

        expect(client).to have_received(:messages).twice
        expect(result).to include(
          outcome: "reply_only",
          reply: described_class::NOTHING_STAGED_REPLY,
          proposed_action: nil,
        )
      end

      it "uses the honest no-proposal fallback when proposal_ready never has a proposal" do
        allow(client).to receive(:messages).and_return(
          complete_turn_result("The action panel is ready.", outcome: "proposal_ready"),
        )

        result = service.respond(messages: [{ role: "user", content: "fix my header" }])

        expect(client).to have_received(:messages).twice
        expect(result).to include(
          outcome: "reply_only",
          reply: described_class::NOTHING_STAGED_REPLY,
          proposed_action: nil,
        )
      end

      it "keeps a real proposal when the model reports reply_only twice" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", {
                        "endpoint" => "create_offer_code",
                        "path_params" => { "link_id" => "prod_1" },
                        "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
                      }),
          complete_turn_result("Nothing changed.", outcome: "reply_only"),
        )

        result = service.respond(messages: [{ role: "user", content: "Make a 20% off code" }])

        expect(client).to have_received(:messages).exactly(3).times
        expect(result[:outcome]).to eq("proposal_ready")
        expect(result[:reply]).to eq(described_class::PROPOSAL_READY_REPLY)
        expect(result[:proposed_action]).to include(type: "api_write")
      end

      it "rejects complete_turn mixed with an API tool without running the API tool" do
        mixed_turn = Ai::AnthropicClient::Result.new(
          text: "Done.",
          tool_uses: [
            {
              id: "toolu_write",
              name: "api_write",
              input: {
                "endpoint" => "create_offer_code",
                "path_params" => { "link_id" => "prod_1" },
                "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
              },
            },
            { id: "toolu_complete", name: "complete_turn", input: { "outcome" => "proposal_ready" } },
          ],
          stop_reason: "tool_use",
        )
        allow(client).to receive(:messages).and_return(
          mixed_turn,
          complete_turn_result("I did not prepare that change.", outcome: "reply_only"),
        )

        result = service.respond(messages: [{ role: "user", content: "Make a 20% off code" }])

        expect(result[:outcome]).to eq("reply_only")
        expect(result[:proposed_action]).to be_nil
      end

      it "shares one retry budget across different terminal failures" do
        allow(client).to receive(:messages).and_return(
          untyped_text_result("I need to retry."),
          complete_turn_result("Staged. Confirm that card.", outcome: "reply_only"),
        )

        result = service.respond(messages: [{ role: "user", content: "fix my header" }])

        expect(client).to have_received(:messages).twice
        expect(result[:reply]).to eq(described_class::NOTHING_STAGED_REPLY)
        expect(result[:proposed_action]).to be_nil
      end

      it "logs a recovered missing terminal marker at info without reporting it" do
        allow(Rails.logger).to receive(:info)
        expect(ErrorNotifier).not_to receive(:notify)
        allow(client).to receive(:messages).and_return(
          untyped_text_result("Your top seller is Cool Ebook."),
          complete_turn_result("Your top seller is Cool Ebook.", outcome: "reply_only"),
        )

        result = service.respond(messages: [{ role: "user", content: "what sells best?" }])

        expect(Rails.logger).to have_received(:info).with("Store agent final turn did not match proposal state (missing_complete_turn, retrying)")
        expect(client).to have_received(:messages).twice
        expect(result[:reply]).to eq("Your top seller is Cool Ebook.")
      end

      it "still reports a missing terminal marker the retry could not recover" do
        expect(ErrorNotifier).to receive(:notify).with(
          "Store agent final turn did not match proposal state",
          reason: "missing_complete_turn",
          outcome: "gave up",
        )
        allow(Rails.logger).to receive(:warn)
        allow(client).to receive(:messages).and_return(untyped_text_result("Still no marker."))

        result = service.respond(messages: [{ role: "user", content: "what sells best?" }])

        expect(Rails.logger).to have_received(:warn).with("Store agent final turn did not match proposal state (missing_complete_turn, gave up)")
        expect(client).to have_received(:messages).twice
        expect(result[:reply]).to eq(described_class::TURN_CONTRACT_FAILURE_REPLY)
      end

      it "still reports a non-marker proposal-state mismatch on the retry" do
        expect(ErrorNotifier).to receive(:notify).with(
          "Store agent final turn did not match proposal state",
          reason: "invalid_complete_turn_outcome",
          outcome: "retrying",
        )
        allow(Rails.logger).to receive(:warn)
        allow(client).to receive(:messages).and_return(
          complete_turn_result("Here you go.", outcome: "not_a_real_outcome"),
          complete_turn_result("Here you go.", outcome: "reply_only"),
        )

        result = service.respond(messages: [{ role: "user", content: "what sells best?" }])

        expect(client).to have_received(:messages).twice
        expect(result[:reply]).to eq("Here you go.")
      end
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

      it "lists only Store Agent-owned webhooks" do
        expect(api_client).to receive(:get).with(
          "/resource_subscriptions",
          { "resource_name" => "sale", "current_oauth_application_only" => true },
        ).and_return({ "success" => true, "resource_subscriptions" => [], "http_status" => 200 })
        allow(client).to receive(:messages).and_return(
          tool_result("api_read", { "endpoint" => "list_resource_subscriptions", "params" => { "resource_name" => "sale" } }),
          text_result("You have no Store Agent webhooks for sales."),
        )

        result = service.respond(messages: [{ role: "user", content: "List my Store Agent sale webhooks" }])

        expect(result[:reply]).to eq("You have no Store Agent webhooks for sales.")
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

      it "forces standalone page lists to stay metadata-only" do
        expect(api_client).to receive(:get).with("/pages", { "metadata_only" => true }).and_return(
          { "success" => true, "pages" => [{ "slug" => "about", "title" => "About" }], "http_status" => 200 },
        )
        allow(client).to receive(:messages).and_return(
          tool_result("api_read", { "endpoint" => "list_pages", "params" => { "metadata_only" => false } }),
          text_result("You have an About page."),
        )

        service.respond(messages: [{ role: "user", content: "What standalone pages do I have?" }])
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
      # tell the model what is actually possible: no dashboard visibility, a brand-new page must
      # carry the whole storefront, and "prepared for confirmation" claims require a real
      # api_write in the same reply.
      it "teaches the model what is possible: no dashboard visibility, no phantom confirmations" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        expect(captured[:system]).to include("cannot see the creator's dashboard")
        expect(captured[:system]).to match(/Settings > Profile > Design/)
        expect(captured[:system]).to include("never send the creator to a screen you are not certain exists")
        expect(captured[:system]).to include(%(<script id="gumroad-data"))
        expect(captured[:system]).to match(/never hard-code the product list/)
        expect(captured[:system]).to match(/Never publish a page that drops the creator's products/)
        expect(captured[:system]).to match(/unless\s+you actually called api_write in this same reply/)
        expect(captured[:system]).to match(/Only call api_write again after they explicitly ask/)
        expect(captured[:system]).to match(/two copies of an action that is\s+unsafe to run twice/)
      end

      # The server replaces the model's final prose with PROPOSAL_READY_REPLY on every proposal
      # turn, so the prompt must say so — otherwise the model authors answer text there that is
      # always discarded, losing the informational half of a combined ask.
      it "teaches the model that proposal-turn text is replaced by server copy, so answers go before api_write" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        expect(captured[:system]).to match(/your final\s+text is replaced with fixed server copy/)
        expect(captured[:system]).to match(/answer any informational part of their request BEFORE calling api_write/)
        expect(captured[:system]).to match(/on a proposal turn that text is replaced with\s+fixed server copy and never shown/)
        expect(captured[:system]).not_to match(/After api_write, tell the creator you've prepared it/)
      end

      # Regression for gumroad-private#1463: asked whether product pages could be styled like the
      # storefront, the agent said no — product pages "aren't customizable", there is "no endpoint
      # and no dashboard setting" for their colours — while the seller's product pages were already
      # rendering their chosen colours from the store theme. When the seller corrected it, the agent
      # argued and invented a "legacy per-product setting" to explain what it could not read. Three
      # things have to be in the prompt: the theme's real reach, "no tool for it" is not "product
      # can't do it", and the creator's observation of their own store wins.
      it "teaches the model that the store theme reaches product pages and that a creator's own observation wins" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        # The theme's real reach, and the exact false claim it must never repeat.
        expect(captured[:system]).to include("every product page")
        expect(captured[:system]).to match(/never tell a creator\s+their product pages can't be styled/)
        expect(captured[:system]).to include("get_user_theme")
        # A missing tool is not a missing feature.
        expect(captured[:system]).to match(/"I have no endpoint for this" is NEVER the\s+same statement as "Gumroad cannot do this"/)
        # Documentation to check against, instead of guessing.
        expect(captured[:system]).to include("search_help_articles")
        expect(captured[:system]).to match(/Before you tell the creator that something is not possible/)
        # Don't argue with the seller, and don't invent an explanation for what you can't see.
        expect(captured[:system]).to match(/Never\s+argue with an observation about their own pages/)
        expect(captured[:system]).to match(/legacy setting/)
        # Route the ask to the settings screen rather than reaching for a custom page as a colour
        # workaround.
        expect(captured[:system]).to match(/Settings > Profile > Design/)
        expect(captured[:system]).not_to match(/support applies/)
        # ...and the authoring rule further down must not contradict that by sending an appearance
        # request into a full-page rewrite, which is how gumroad-private#984 happened.
        expect(captured[:system]).to match(/NO custom HTML page yet and wants a custom page/)
        expect(captured[:system]).to match(/never author a whole custom page as a way to change a colour/)
        expect(captured[:system]).not_to match(/NO custom HTML page yet and wants an appearance change/)
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

      # Both payload arrays are capped at Pages::ProfileData::MAX_ITEMS, so a page that renders
      # either one has to be told to disclose the cap. Products alone is not enough: a posts
      # archive rendering the first 100 of 260 reads to the creator as posts having vanished,
      # which is the same defect (gumroad-private#1522).
      it "requires a visible count whenever either the product or the post list is capped" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        expect(captured[:system]).to include("products_total")
        expect(captured[:system]).to include("posts_total")
        expect(captured[:system]).to match(/posts_total\s+exceeds posts\.length/)
        expect(captured[:system]).to match(/MUST show a visible count for that section/)
        expect(captured[:system]).to match(/Showing 100 of 260 posts/)
      end

      # Regression for gumroad-private#1466: a seller asked about the `<h2>Albums</h2>` on his own
      # live storefront and about the pages he had created. The agent could read only the profile's
      # custom HTML, which was nil, so it concluded his profile was Gumroad's untouched default and
      # spent 45 minutes telling him: the heading was "actually Products, not Albums", it was
      # probably his browser cache, standalone pages don't exist on Gumroad, and the CLI's own
      # `pages push`/`pages preview` commands "aren't real Gumroad features". Every one of those was
      # false. The heading was his own section header; the pages feature and the CLI commands ship.
      #
      # The prompt now has to name all three storefront surfaces, and — the load-bearing part —
      # state that an empty custom HTML read does NOT mean the profile is the default.
      it "teaches the model that the storefront has three surfaces and that empty custom HTML is not an empty profile" do
        captured = nil
        allow(client).to receive(:messages) do |args|
          captured = args
          text_result("ok")
        end

        service.respond(messages: [{ role: "user", content: "hi" }])

        # The inference that caused the whole incident.
        expect(captured[:system]).to match(/get_user_custom_html coming back empty means\s+only "no custom HTML" — it does NOT mean the storefront is Gumroad's untouched default/)
        # Headings on the default profile are the seller's own, and are readable.
        expect(captured[:system]).to include("get_user_profile_layout")
        expect(captured[:system]).to match(/never claim the\s+default profile ships a heading of its own/)
        # Standalone pages, and the CLI that drives them, are real.
        expect(captured[:system]).to include("list_pages")
        expect(captured[:system]).to match(/gumroad pages pull\/preview\/push/)
        expect(captured[:system]).to match(/NEVER tell a creator that\s+standalone\s+pages don't exist on Gumroad/)
        # It can list and read pages but cannot mutate them, so it must not offer to.
        expect(captured[:system]).to include("get_page")
        expect(captured[:system]).not_to include("update_page")
        expect(captured[:system]).to match(/you cannot create, update, or delete them/)
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
          text_result("I've prepared a 20% off code called LAUNCH for your confirmation.", outcome: "proposal_ready"),
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
          text_result("Prepared the change.", outcome: "proposal_ready"),
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
          text_result("Prepared.", outcome: "proposal_ready"),
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
          text_result("Prepared.", outcome: "proposal_ready"),
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
          text_result("Prepared.", outcome: "proposal_ready"),
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
          text_result("Prepared.", outcome: "proposal_ready"),
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
          text_result("Prepared.", outcome: "proposal_ready"),
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
          text_result("Prepared.", outcome: "proposal_ready"),
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

      it "normalizes proposed product currency code case and whitespace before storing the action" do
        allow(client).to receive(:messages).and_return(
          tool_result("api_write", { "endpoint" => "create_product", "params" => { "name" => "Workbook", "price" => 21_999, "price_currency_type" => " ZAR " } }),
          text_result("Prepared."),
        )

        result = service.respond(messages: [{ role: "user", content: "make a ZAR product" }])

        expect(result[:proposed_action]).to include(
          type: "api_write",
          params: include("params" => include("price_currency_type" => "zar")),
        )
        expect(result[:proposed_action][:fields]).to include({ label: "Price currency type", value: "zar" })
      end

      describe "custom-page read preconditions" do
        page_write_cases = [
          {
            write_endpoint: "update_user_custom_html",
            read_endpoint: "get_user_custom_html",
            path_params: {},
            read_path: "/user/custom_html",
            observable_read_path: "/user/custom_html",
            params: { "custom_html" => "<main>New profile</main>" },
          },
          {
            write_endpoint: "edit_user_custom_html",
            read_endpoint: "get_user_custom_html",
            path_params: {},
            read_path: "/user/custom_html",
            observable_read_path: "/user/custom_html",
            params: { "find" => "<h1>Old</h1>", "replace" => "<h1>New</h1>" },
          },
          {
            write_endpoint: "update_product_custom_html",
            read_endpoint: "get_product_custom_html",
            path_params: { "id" => "product-a" },
            read_path: "/products/product-a/custom_html",
            observable_read_path: "/products/:id/custom_html",
            params: { "custom_html" => %(<main><a data-gumroad-action="buy">Buy</a></main>) },
          },
          {
            write_endpoint: "edit_product_custom_html",
            read_endpoint: "get_product_custom_html",
            path_params: { "id" => "product-a" },
            read_path: "/products/product-a/custom_html",
            observable_read_path: "/products/:id/custom_html",
            params: { "find" => "<h1>Old</h1>", "replace" => "<h1>New</h1>" },
          },
        ].freeze

        page_write_cases.each do |page_case|
          it "blocks #{page_case[:write_endpoint]} until its declared full read succeeds" do
            captured = nil
            first = true
            expect(Rails.logger).to receive(:warn).with(described_class::MISSING_REQUIRED_READ_MESSAGE)
            expect(ErrorNotifier).to receive(:notify).with(
              described_class::MISSING_REQUIRED_READ_MESSAGE,
              exclude_request_context: true,
              write_endpoint: page_case[:write_endpoint],
              required_read_endpoint: page_case[:read_endpoint],
              required_read_path: page_case[:observable_read_path],
            )
            allow(client).to receive(:messages) do |args|
              if first
                first = false
                tool_result("api_write", {
                              "endpoint" => page_case[:write_endpoint],
                              "path_params" => page_case[:path_params],
                              "params" => page_case[:params],
                            })
              else
                captured = captured_tool_result(args)
                text_result("I need to read the current page first.")
              end
            end

            result = service.respond(messages: [{ role: "user", content: "Change my custom page" }])

            expect(result[:proposed_action]).to be_nil
            expect(captured["error"]).to include(
              "successful full read",
              "Only if the seller explicitly requested this custom-page work",
              "Otherwise, do not read the page body and do not retry the write",
              "Status or metadata-only reads do not count",
            )
            expect(captured["corrective_action"]).to eq(
              "condition" => "The seller explicitly requested this custom-page work.",
              "if_requested" => {
                "tool" => "api_read",
                "endpoint" => page_case[:read_endpoint],
                "path_params" => page_case[:path_params],
                "after_success" => {
                  "action" => "retry_write",
                  "endpoint" => page_case[:write_endpoint],
                  "timing" => "this_turn",
                },
              },
              "otherwise" => {
                "action" => "do_not_read_or_retry",
                "instruction" => "Do not read the page body and do not retry the write.",
              },
            )
          end

          it "allows #{page_case[:write_endpoint]} after its declared full read succeeds for the same target" do
            expect(api_client).to receive(:get).with(page_case[:read_path], {}).and_return(
              { "success" => true, "custom_html" => "<h1>Current</h1>", "http_status" => 200 },
            )
            allow(client).to receive(:messages).and_return(
              tool_result("api_read", {
                            "endpoint" => page_case[:read_endpoint],
                            "path_params" => page_case[:path_params],
                          }),
              tool_result("api_write", {
                            "endpoint" => page_case[:write_endpoint],
                            "path_params" => page_case[:path_params],
                            "params" => page_case[:params],
                          }),
              text_result("I read the current page and prepared the change.", outcome: "proposal_ready"),
            )

            result = service.respond(messages: [{ role: "user", content: "Change my custom page" }])

            expect(result[:proposed_action]).to include(
              type: "api_write",
              params: include(
                "endpoint" => page_case[:write_endpoint],
                "path_params" => page_case[:path_params],
              ),
            )
          end
        end

        it "does not let a full read of product A unlock a write to product B" do
          captured = nil
          expect(api_client).to receive(:get).with("/products/product-a/custom_html", {}).and_return(
            { "success" => true, "custom_html" => "<h1>A</h1>", "http_status" => 200 },
          )
          expect(ErrorNotifier).to receive(:notify).with(
            described_class::MISSING_REQUIRED_READ_MESSAGE,
            exclude_request_context: true,
            write_endpoint: "update_product_custom_html",
            required_read_endpoint: "get_product_custom_html",
            required_read_path: "/products/:id/custom_html",
          )
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_read", {
                          "endpoint" => "get_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                        }),
            tool_result("api_write", {
                          "endpoint" => "update_product_custom_html",
                          "path_params" => { "id" => "product-b" },
                          "params" => { "custom_html" => "<main>Product B</main>" },
                        }),
            text_result("I need to read product B first."),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args) if replies.one?
            replies.shift
          end

          result = service.respond(messages: [{ role: "user", content: "Replace product B's page" }])

          expect(result[:proposed_action]).to be_nil
          expect(captured.dig("corrective_action", "if_requested", "path_params")).to eq("id" => "product-b")
        end

        it "does not let a full read from a prior turn unlock the current turn" do
          captured_results = []
          expect(api_client).to receive(:get).with("/products/product-a/custom_html", {}).and_return(
            { "success" => true, "custom_html" => "<h1>A</h1>", "http_status" => 200 },
          )
          expect(ErrorNotifier).to receive(:notify).with(
            described_class::MISSING_REQUIRED_READ_MESSAGE,
            exclude_request_context: true,
            write_endpoint: "edit_product_custom_html",
            required_read_endpoint: "get_product_custom_html",
            required_read_path: "/products/:id/custom_html",
          )
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_read", {
                          "endpoint" => "get_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                        }),
            text_result("I found the current page."),
            tool_result("api_write", {
                          "endpoint" => "edit_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                          "params" => { "find" => "<h1>A</h1>", "replace" => "<h1>Updated</h1>" },
                        }),
            text_result("I need to read it again in this turn."),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args)
            captured_results << captured if captured
            replies.shift
          end

          service.respond(messages: [{ role: "user", content: "What is on product A's page?" }])
          second_turn = service.respond(messages: [{ role: "user", content: "Change its heading" }])

          expect(second_turn[:proposed_action]).to be_nil
          expect(captured_results.last["error"]).to include("in this turn")
        end

        it "does not let a product metadata read unlock a custom-page write" do
          captured = nil
          expect(api_client).to receive(:get).with("/products/product-a", {}).and_return(
            { "success" => true, "product" => { "id" => "product-a", "name" => "Product A" }, "http_status" => 200 },
          )
          expect(ErrorNotifier).to receive(:notify).with(
            described_class::MISSING_REQUIRED_READ_MESSAGE,
            exclude_request_context: true,
            write_endpoint: "update_product_custom_html",
            required_read_endpoint: "get_product_custom_html",
            required_read_path: "/products/:id/custom_html",
          )
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_read", {
                          "endpoint" => "get_product",
                          "path_params" => { "id" => "product-a" },
                        }),
            tool_result("api_write", {
                          "endpoint" => "update_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                          "params" => { "custom_html" => "<main>Replacement</main>" },
                        }),
            text_result("I need the full page, not its metadata."),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args) if replies.one?
            replies.shift
          end

          result = service.respond(messages: [{ role: "user", content: "Replace product A's page" }])

          expect(result[:proposed_action]).to be_nil
          expect(captured["error"]).to include("metadata-only reads do not count")
        end

        it "does not turn an unsolicited custom-page write into unconditional read and retry instructions" do
          captured = nil
          expect(api_client).not_to receive(:get)
          allow(ErrorNotifier).to receive(:notify)
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_write", {
                          "endpoint" => "update_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                          "params" => { "custom_html" => "<main>Blue theme</main>" },
                        }),
            text_result("That was not requested, so I will not inspect or change the custom page."),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args) if replies.one?
            replies.shift
          end

          result = service.respond(messages: [{ role: "user", content: "Why is my product page blue?" }])

          expect(result[:proposed_action]).to be_nil
          expect(captured["error"]).to include(
            "Only if the seller explicitly requested this custom-page work",
            "Otherwise, do not read the page body and do not retry the write",
          )
          expect(captured["corrective_action"]).not_to have_key("tool")
          expect(captured.dig("corrective_action", "condition")).to eq(
            "The seller explicitly requested this custom-page work.",
          )
          expect(captured.dig("corrective_action", "otherwise")).to eq(
            "action" => "do_not_read_or_retry",
            "instruction" => "Do not read the page body and do not retry the write.",
          )
        end

        it "gives explicitly requested page work the exact read target and allows a retry after the read succeeds" do
          captured_results = []
          expect(api_client).to receive(:get).with("/products/product-a/custom_html", {}).and_return(
            { "success" => true, "custom_html" => "<h1>Current</h1>", "http_status" => 200 },
          )
          allow(ErrorNotifier).to receive(:notify)
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_write", {
                          "endpoint" => "edit_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                          "params" => { "find" => "<h1>Current</h1>", "replace" => "<h1>Updated</h1>" },
                        }),
            tool_result("api_read", {
                          "endpoint" => "get_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                        }),
            tool_result("api_write", {
                          "endpoint" => "edit_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                          "params" => { "find" => "<h1>Current</h1>", "replace" => "<h1>Updated</h1>" },
                        }),
            text_result("I read the current page and prepared the requested heading change.", outcome: "proposal_ready"),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args)
            captured_results << captured if captured
            replies.shift
          end

          result = service.respond(messages: [{ role: "user", content: "On product A's custom page, change the heading to Updated" }])

          correction = captured_results.first.fetch("corrective_action")
          expect(correction.dig("if_requested", "endpoint")).to eq("get_product_custom_html")
          expect(correction.dig("if_requested", "path_params")).to eq("id" => "product-a")
          expect(correction.dig("if_requested", "after_success")).to eq(
            "action" => "retry_write",
            "endpoint" => "edit_product_custom_html",
            "timing" => "this_turn",
          )
          expect(result[:proposed_action]).to include(
            type: "api_write",
            params: include(
              "endpoint" => "edit_product_custom_html",
              "path_params" => { "id" => "product-a" },
            ),
          )
        end

        it "does not send a model-supplied target id to guard observability" do
          sentinel = "raw-seller-chat-DO-NOT-SEND"
          expect(Rails.logger).to receive(:warn).with(described_class::MISSING_REQUIRED_READ_MESSAGE)
          expect(ErrorNotifier).to receive(:notify).with(
            described_class::MISSING_REQUIRED_READ_MESSAGE,
            exclude_request_context: true,
            write_endpoint: "update_product_custom_html",
            required_read_endpoint: "get_product_custom_html",
            required_read_path: "/products/:id/custom_html",
          )
          allow(client).to receive(:messages).and_return(
            tool_result("api_write", {
                          "endpoint" => "update_product_custom_html",
                          "path_params" => { "id" => sentinel },
                          "params" => { "custom_html" => "<main>Replacement</main>" },
                        }),
            text_result("I need to read the current page first."),
          )

          result = service.respond(messages: [{ role: "user", content: sentinel }])

          expect(result[:proposed_action]).to be_nil
        end

        it "rejects a metadata-only param on the full-read endpoint and keeps the write locked" do
          captured_results = []
          expect(api_client).not_to receive(:get)
          allow(ErrorNotifier).to receive(:notify)
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_read", {
                          "endpoint" => "get_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                          "params" => { "metadata_only" => true },
                        }),
            tool_result("api_write", {
                          "endpoint" => "update_product_custom_html",
                          "path_params" => { "id" => "product-a" },
                          "params" => { "custom_html" => "<main>Replacement</main>" },
                        }),
            text_result("I still need the declared full read."),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args)
            captured_results << captured if captured
            replies.shift
          end

          result = service.respond(messages: [{ role: "user", content: "Replace product A's page" }])

          expect(result[:proposed_action]).to be_nil
          expect(captured_results.first["error"]).to include("metadata_only")
          expect(captured_results.last["error"]).to include("successful full read")
        end

        it "does not let a failed full read unlock a custom-page write" do
          captured = nil
          expect(api_client).to receive(:get).with("/user/custom_html", {}).and_return(
            { "success" => false, "message" => "Unavailable", "http_status" => 200 },
          )
          allow(ErrorNotifier).to receive(:notify)
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_read", { "endpoint" => "get_user_custom_html" }),
            tool_result("api_write", {
                          "endpoint" => "update_user_custom_html",
                          "params" => { "custom_html" => "<main>Replacement</main>" },
                        }),
            text_result("The read failed, so I cannot prepare this yet."),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args) if replies.one?
            replies.shift
          end

          result = service.respond(messages: [{ role: "user", content: "Replace my profile page" }])

          expect(result[:proposed_action]).to be_nil
          expect(captured["error"]).to include("successful full read")
        end

        it "does not let a non-2xx full read unlock a custom-page write when success is omitted" do
          captured = nil
          expect(api_client).to receive(:get).with("/user/custom_html", {}).and_return(
            { "message" => "Unavailable", "http_status" => 503 },
          )
          allow(ErrorNotifier).to receive(:notify)
          allow(Rails.logger).to receive(:warn)
          replies = [
            tool_result("api_read", { "endpoint" => "get_user_custom_html" }),
            tool_result("api_write", {
                          "endpoint" => "update_user_custom_html",
                          "params" => { "custom_html" => "<main>Replacement</main>" },
                        }),
            text_result("The read failed, so I cannot prepare this yet."),
          ]
          allow(client).to receive(:messages) do |args|
            captured = captured_tool_result(args) if replies.one?
            replies.shift
          end

          result = service.respond(messages: [{ role: "user", content: "Replace my profile page" }])

          expect(result[:proposed_action]).to be_nil
          expect(captured["error"]).to include("successful full read")
        end

        it "requires the model to receive the full-read result before it can propose the write" do
          simultaneous_read_and_write = Ai::AnthropicClient::Result.new(
            text: "",
            tool_uses: [
              {
                id: "toolu_read",
                name: "api_read",
                input: {
                  "endpoint" => "get_product_custom_html",
                  "path_params" => { "id" => "product-a" },
                },
              },
              {
                id: "toolu_write",
                name: "api_write",
                input: {
                  "endpoint" => "update_product_custom_html",
                  "path_params" => { "id" => "product-a" },
                  "params" => { "custom_html" => "<main>Speculative replacement</main>" },
                },
              },
            ],
            stop_reason: "tool_use",
          )
          expect(api_client).to receive(:get).with("/products/product-a/custom_html", {}).and_return(
            { "success" => true, "custom_html" => "<h1>Current</h1>", "http_status" => 200 },
          )
          allow(ErrorNotifier).to receive(:notify)
          allow(Rails.logger).to receive(:warn)
          allow(client).to receive(:messages).and_return(
            simultaneous_read_and_write,
            text_result("I read the page, but I need to prepare the write in a new tool step."),
          )

          result = service.respond(messages: [{ role: "user", content: "Replace product A's page" }])

          expect(result[:proposed_action]).to be_nil
        end
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
            text_result("I've prepared the FIRST code for your confirmation.", outcome: "proposal_ready")
          end
        end

        result = service.respond(messages: [{ role: "user", content: "make two codes" }])

        expect(result[:proposed_action]).to include(type: "api_write", params: include("params" => include("name" => "FIRST")))
        expect(captured_results.last).to include("error")
        expect(captured_results.last["error"]).to match(/one change/i)
      end
    end

    context "when the reply claims a change is staged but nothing was proposed" do
      # The confirmation card is rendered purely from the proposed action, so a reply asserting
      # "Staged. Confirm that card" with no action tells the seller to click a button that does not
      # exist. The service must retry the turn and, failing that, be honest.
      let(:write_use) do
        tool_result("api_write", {
                      "endpoint" => "create_offer_code",
                      "path_params" => { "link_id" => "p1" },
                      "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
                    })
      end

      it "re-asks the model to stage it for real and returns the recovered turn" do
        replies = [
          text_result("Staged. Confirm that card and the discount goes live."),
          write_use,
          text_result("Staged now — confirm the card.", outcome: "proposal_ready"),
        ]
        allow(client).to receive(:messages) { replies.shift }

        result = service.respond(messages: [{ role: "user", content: "make a 20% code" }])

        expect(result[:proposed_action]).to include(type: "api_write")
        expect(result[:reply]).to eq(described_class::PROPOSAL_READY_REPLY)
        expect(replies).to be_empty
      end

      it "tells the model exactly what went wrong and returns the model's honest correction" do
        captured = []
        # A model that complies with the correction says so plainly. That reply is truthful with no
        # proposed action, so it must reach the seller unchanged — if the guard flagged it too, the
        # correction branch could never succeed and every phantom claim would end in the fallback.
        correction_reply = "Nothing is prepared right now — want me to set that discount up?"
        replies = [text_result("Staged. Confirm that card."), text_result(correction_reply)]
        allow(client).to receive(:messages) do |args|
          captured = args[:messages]
          replies.shift
        end

        result = service.respond(messages: [{ role: "user", content: "make a 20% code" }])

        expect(result[:reply]).to eq(correction_reply)
        expect(captured.last[:role]).to eq("user")
        correction_result = captured.last[:content].sole
        expect(JSON.parse(correction_result[:content])).to eq("error" => described_class::STAGED_CLAIM_CORRECTION)
        # Rejected terminal tools are replayed with a matching tool_result, which keeps the
        # correction valid under Anthropic's tool-use message protocol.
        expect(captured[-2][:role]).to eq("assistant")
        expect(captured[-2][:content]).to include(
          type: "tool_use",
          id: "toolu_complete",
          name: "complete_turn",
          input: { "outcome" => "reply_only" },
        )
      end

      it "does not ask for a correction the guard would reject" do
        # The correction tells the model what to say when it can't stage the change. If that wording
        # itself tripped the guard, a compliant model would be silenced.
        compliant = [
          "No change is prepared and I'm not waiting on you.",
          "Nothing is prepared — I couldn't set that up.",
        ]
        compliant.each do |reply|
          expect(described_class::STAGED_CLAIM_PATTERNS.any? { |pattern| reply.match?(pattern) }).to be(false), reply
        end
      end

      it "gives up honestly rather than repeating the false claim" do
        allow(client).to receive(:messages).and_return(text_result("Staged. The confirm button is already there — click it."))

        result = service.respond(messages: [{ role: "user", content: "make a 20% code" }])

        expect(result[:reply]).to eq(described_class::NOTHING_STAGED_REPLY)
        expect(result[:reply]).to start_with("That change wasn't prepared")
        expect(result[:reply]).not_to start_with("Something went wrong")
        expect(result[:proposed_action]).to be_nil
        # The honest fallback must not itself read as a staging claim, or the guard would flag its
        # own output on the next turn.
        expect(described_class::STAGED_CLAIM_PATTERNS.any? { |p| described_class::NOTHING_STAGED_REPLY.match?(p) }).to be(false)
      end

      it "reports every occurrence so the rate is visible outside a database read" do
        sensitive_reply = "Staged. Confirm that card for buyer@example.com using secret-token."
        allow(client).to receive(:messages).and_return(text_result(sensitive_reply))
        # Both the retry and the give-up report under one fixed message so Sentry groups them.
        # Reporting only the give-up would hide every turn the retry recovered.
        expect(ErrorNotifier).to receive(:notify)
          .with("Store agent claimed a staged change with no proposed action", outcome: "retrying")
          .once
        expect(ErrorNotifier).to receive(:notify)
          .with("Store agent claimed a staged change with no proposed action", outcome: "gave up, told the seller nothing was prepared")
          .once
        expect(Rails.logger).to receive(:warn).twice do |message|
          expect(message).not_to include("buyer@example.com", "secret-token")
        end

        service.respond(messages: [{ role: "user", content: "make a 20% code" }])
      end

      it "leaves a legitimate staging claim alone when the action really was proposed" do
        replies = [write_use, text_result("Staged. Confirm that card and it's live.", outcome: "proposal_ready")]
        allow(client).to receive(:messages) { replies.shift }

        result = service.respond(messages: [{ role: "user", content: "make a 20% code" }])

        expect(result[:reply]).to eq(described_class::PROPOSAL_READY_REPLY)
        expect(result[:proposed_action]).to include(type: "api_write")
      end

      it "keeps subjectless parsing bounded on long near-matches" do
        replies = [
          "Staged deletion of the #{"very " * 4_000}last draft is permanent. Approve it.",
          "Staged again. #{"The confirm card should be back " * 2_000}but it is not.",
          "Staged deletion of the draft (#{"x" * 10_000}. Approve it.",
          "Staged deletion of the draft (#{"x" * 121}). Approve it.",
          "Staged again#{" " * 10_000}x",
          "Staged deletion of the draft. Approve it#{" " * 20_000}x",
        ]

        matches = Timeout.timeout(1) do
          replies.map { |reply| service.send(:phantom_staged_claim?, reply:, proposed_action: nil) }
        end

        expect(matches).to eq([false, false, false, false, false, false])
      end

      it "leaves truthful replies that use the same words alone" do
        # A match REPLACES the model's reply, so a false positive tells the seller a change doesn't
        # exist when it does — worse than the phantom claim. Every one of these is truthful with no
        # proposed action this turn, and none may be swallowed.
        innocuous = [
          # offers and explanations
          "Want me to prepare that discount for you?",
          "I've prepared a summary of your sales for the month.",
          "Any change I make needs your confirmation before it takes effect.",
          "Changes get staged for you to review before anything goes live.",
          # negations — replacing these would contradict the model's own honest answer
          "Nothing is staged right now.",
          "No change is prepared yet — tell me what you'd like and I'll set it up.",
          "That isn't staged, so there's nothing waiting on you.",
          "It isn’t staged.",
          "Nothing’s staged.",
          "I staged nothing.",
          "I staged no change.",
          "I've prepared nothing for your confirmation.",
          "I prepared no change for your approval.",
          "It isn't ready for you to confirm yet.",
          # already-applied — the fallback would falsely claim the change never happened
          "You already confirmed that discount, so it's live now.",
          "That change was already applied.",
          "I staged it and you already applied it.",
          "I've prepared it for confirmation, and you already applied it.",
          "I staged it earlier, and you already confirmed it.",
          "I’ve staged it before.",
          "I have staged this many times.",
          "I’ve staged similar changes in the past.",
          "I’ve staged no product update.",
          "The earlier reply said: I’ve staged it.",
          "For context, the earlier reply said: I have now staged it for confirmation.",
          # a card on an EARLIER message can genuinely still be pending
          "The confirm button is on my earlier message — scroll up to that card.",
          "The confirm button is on the earlier message — scroll up.",
          "It's staged on my earlier message — scroll up.",
          "I staged that yesterday; the card is on my earlier message.",
          "Confirm it on the card from my earlier message.",
          # general and hypothetical explanations are not claims about a change prepared this turn
          "Changes are staged, reviewed, then confirmed.",
          "The change is staged, reviewed, then applied after confirmation.",
          "When you are ready to confirm, use the pending card.",
          "Nothing is staged and ready for you to confirm.",
          "Nothing is staged. When you're ready to confirm the details, I'll prepare it.",
          "Nothing is staged, so if I prepare it later, confirm it below.",
          "If it is staged, you will see a card.",
          "When it is staged, a card appears.",
          "Ready to confirm?",
          "Staged?",
          "I prepared an explanation of the confirmation process.",
          "I've prepared a draft email for your approval below.",
          "No new confirmation card was created.",
          "There is no confirmation button below.",
          "It is staged and already applied.",
          "A new confirmation card appears after you stage a change.",
          "A new confirmation card appears below after you stage a change.",
          "A new confirmation card would appear below if I staged the change.",
          "The confirmation card appears below when a change is staged.",
          "The confirmation card appears below only after api_write succeeds.",
          "This request is still non-staged.",
          # Subjectless detection stays at the measured reply start and exact action/card frames.
          "Example output: Staged deletion of the last draft. Approve it.",
          "Do not say: Staged again. Tap the card below.",
          "Staged deletion of the draft is permanent. Approve it.",
          "Staged deletion of the very last remaining draft is permanent. Approve it.",
          "Staged deletion of the draft is explained in this block. Click it.",
          "Staged deletion of the draft is permanent. This is a block. Click it.",
          "Staged deletion of the last Bidcheckpro draft (from my previous message). Approve it.",
          "Staged deletion of the draft. Approve it only in the demo.",
          "Staged removal of the block. Tap the card, then watch the recording.",
          "Staged again. It's on my earlier message.",
          "Staged again. You already applied it.",
          "You have 3 products.",
        ]

        innocuous.each do |reply|
          allow(client).to receive(:messages).and_return(text_result(reply))
          result = service.respond(messages: [{ role: "user", content: "hi" }])
          expect(result[:reply]).to eq(reply), "swallowed a truthful reply: #{reply}"
        end
      end

      it "still catches the phantom shapes seen in production" do
        # Sampled from real ai_messages rows whose metadata carried no proposed_action.
        phantoms = [
          "Staged. Confirm that card and the header grid becomes a three-column layout.",
          "Staged now. The card with a confirm button should appear in this chat.",
          "I've prepared that change for your confirmation.",
          "I’ve prepared that change for your confirmation.",
          "I've prepared that change for your approval.",
          "I staged the change for your confirmation.",
          "That's staged and ready to confirm.",
          "Fresh confirm card on this message.",
          "Staged",
          "Staged: confirm the card.",
          "The change has been staged. Confirm the card.",
          "Your changes are staged and ready to confirm.",
          "The requested changes are staged. Confirm the card below.",
          "That change has been staged and is ready for approval.",
          "The discount is prepared and ready for you to confirm.",
          "I have staged it again because the card on the earlier message is gone.",
          "I've prepared the discount — please confirm when you're ready.",
          "Ready for you to confirm.",
          "The change is ready for you to confirm.",
          "It's ready for confirmation.",
          "The update is staged and ready to confirm.",
          "Your discount is staged and ready for you to confirm.",
          "Your product update is staged and ready for confirmation.",
          "Your product is staged and ready for approval.",
          "The offer code is staged and ready for approval.",
          "The requested update has been staged. Please confirm.",
          "I went ahead and staged the discount for your confirmation.",
          "I've gone ahead and staged the update for your confirmation.",
          "Confirm the card below.",
          "All staged — confirm below.",
          "Successfully staged — confirm below.",
          "Staged successfully — confirm below.",
          "Staged, but not already applied.",
          "It's staged but hasn't already been applied.",
          # The two exact post-#6506 survivors plus two bounded synthetic sibling frames.
          "Staged deletion of the last Bidcheckpro draft (enviac, $149). Approve it, then tell me if you want to move on to creating Auru API at $25.",
          "Staged again. The confirm card should be back — tap it whenever you're ready and the archive goes live.",
          "Staged removal of the duplicate mobile block. Tap the card to apply it.",
          "Staged the price change. Click that card and it goes live.",
        ]

        phantoms.each do |reply|
          allow(client).to receive(:messages).and_return(text_result(reply))
          result = service.respond(messages: [{ role: "user", content: "fix my header" }])
          expect(result[:reply]).to eq(described_class::NOTHING_STAGED_REPLY), "missed a phantom claim: #{reply}"
        end
      end

      it "catches a current staging claim after an earlier negated clause" do
        mixed_claims = [
          "Nothing was staged before. I've now staged the discount for your confirmation.",
          "That wasn't staged earlier, but it's staged now — confirm the card.",
          "No change was prepared before — I've prepared it for your confirmation now.",
          "Nothing was staged before;I've now staged the discount for your confirmation.",
          "Nothing was staged before\nI've now staged the discount for your confirmation.",
          "No change was prepared before—I've prepared it for your confirmation now.",
          "Nothing was staged before, and I staged it for your confirmation.",
          "Nothing was staged before; now I have staged it for confirmation.",
          "Nothing was staged before, though I have now staged it for confirmation.",
          "It wasn't staged before, so I staged it now.",
          "No change was prepared before, although I have now prepared it for approval.",
          "I staged that yesterday; it was already applied. I've now staged the replacement for your confirmation.",
          "The earlier reply said: Nothing was staged. Staged again. The confirm card should be back — tap it whenever you're ready and the archive goes live.",
          "The previous message read: Nothing was staged; Staged deletion of the last Bidcheckpro draft (enviac, $149). Approve it, then tell me if you want to move on to creating Auru API at $25.",
          "For context, the earlier reply said: Nothing was staged. I have now staged it for confirmation.",
        ]

        mixed_claims.each do |reply|
          allow(client).to receive(:messages).and_return(text_result(reply))
          result = service.respond(messages: [{ role: "user", content: "try that change again" }])
          expect(result[:reply]).to eq(described_class::NOTHING_STAGED_REPLY), "missed a mixed claim: #{reply}"
        end
      end

      it "reserves enough recovery turns when the claim arrives at the normal iteration cap" do
        stub_const("#{described_class}::MAX_TOOL_ITERATIONS", 1)
        claim = "Staged. Confirm that card."
        replies = [text_result(claim), write_use, text_result("Staged now — confirm the card.", outcome: "proposal_ready")]
        allow(client).to receive(:messages) { replies.shift }

        result = service.respond(messages: [{ role: "user", content: "make a 20% code" }])

        expect(client).to have_received(:messages)
          .exactly(described_class::MAX_TOOL_ITERATIONS + described_class::TURN_CONTRACT_RECOVERY_ITERATIONS).times
        expect(replies).to be_empty
        expect(result[:reply]).to eq(described_class::PROPOSAL_READY_REPLY)
        expect(result[:proposed_action]).to include(type: "api_write")
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

    it "clears unvalidated text when the model stream fails before the terminal outcome" do
      allow(client).to receive(:stream_messages) do |**_args, &on_text|
        on_text.call("I prepared that change.")
        raise Ai::AnthropicClient::Error, "stream failed"
      end
      events = []
      reply_completed = false

      expect do
        service.respond_streaming(
          messages: [{ role: "user", content: "fix my header" }],
          on_reply_complete: ->(_turn) { reply_completed = true },
        ) { |event, payload| events << [event, payload] }
      end.to raise_error(Ai::AnthropicClient::Error, "stream failed")

      expect(events).to eq(
        [
          [:token, { text: "I prepared that change." }],
          [:reset, {}],
        ],
      )
      expect(reply_completed).to be(false)
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
      expect(completed_turn).to eq(
        outcome: "reply_only",
        reply: "Here are your numbers.",
        proposed_action: nil,
        objects: [],
      )
      expect(result[:suggestions]).to eq(["Show my sales"])
    end

    it "emits a proposed action over the stream without mutating" do
      stub_stream_turns(
        { stream: [], result: tool_result("api_write", { "endpoint" => "create_offer_code", "path_params" => { "link_id" => "p1" }, "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" } }) },
        {
          stream: ["I've prepared that discount for your confirmation."],
          result: text_result("I've prepared that discount for your confirmation.", outcome: "proposal_ready"),
        },
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

    it "persists a proposal before streaming its server-owned confirmation" do
      model_reply = "The action panel is ready."
      stub_stream_turns(
        { stream: [], result: tool_result("api_write", { "endpoint" => "create_offer_code", "path_params" => { "link_id" => "p1" }, "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" } }) },
        {
          stream: [model_reply],
          result: text_result(model_reply, outcome: "proposal_ready"),
        },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))
      order = []

      result = service.respond_streaming(
        messages: [{ role: "user", content: "make a 20% code" }],
        on_reply_complete: ->(turn) { order << [:persist, turn.dup] },
      ) do |event, payload|
        order << [event, payload]
      end

      persisted_index = order.index { |event, _| event == :persist }
      reply_index = order.index { |event, payload| event == :token && payload[:text] == described_class::PROPOSAL_READY_REPLY }
      proposal_index = order.index { |event, _| event == :proposed_action }
      expect(persisted_index).to be < reply_index
      expect(reply_index).to be < proposal_index
      expect(order).not_to include([:token, { text: model_reply }])
      expect(result[:reply]).to eq(described_class::PROPOSAL_READY_REPLY)
      expect(result[:outcome]).to eq("proposal_ready")
    end

    it "resets server-owned confirmation copy when no proposal backs the stream" do
      reply = described_class::PROPOSAL_READY_REPLY
      stub_stream_turns(
        { stream: [reply], result: text_result(reply) },
        { stream: [reply], result: text_result(reply) },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))

      events, result = collect_events([{ role: "user", content: "fix my header" }])

      fallback_index = events.index { |event, payload| event == :token && payload[:text] == described_class::NOTHING_STAGED_REPLY }
      expect(events.count { |event, _| event == :reset }).to eq(2)
      expect(events.rindex { |event, _| event == :reset }).to be < fallback_index
      expect(result[:reply]).to eq(described_class::NOTHING_STAGED_REPLY)
      expect(result[:proposed_action]).to be_nil
      expect(events.any? { |event, _| event == :proposed_action }).to be(false)
    end

    it "enforces custom-page reads while streaming and resets them between turns" do
      turns = [
        { result: tool_result("api_read", { "endpoint" => "get_product_custom_html", "path_params" => { "id" => "product-a" } }, id: "toolu_read") },
        { result: tool_result("api_write", {
                                "endpoint" => "update_product_custom_html",
                                "path_params" => { "id" => "product-a" },
                                "params" => { "custom_html" => "<main>First change</main>" },
                              }, id: "toolu_first_write") },
        { stream: ["The first change is ready."], result: text_result("The first change is ready.", outcome: "proposal_ready") },
        { result: tool_result("api_write", {
                                "endpoint" => "update_product_custom_html",
                                "path_params" => { "id" => "product-a" },
                                "params" => { "custom_html" => "<main>Second change</main>" },
                              }, id: "toolu_second_write") },
        { stream: ["I need to read it again."], result: text_result("I need to read it again.") },
      ]
      captured_results = []
      allow(client).to receive(:stream_messages) do |args, &on_text|
        captured = captured_tool_result(args)
        captured_results << captured if captured
        turn = turns.shift
        Array(turn[:stream]).each { |piece| on_text&.call(piece) }
        turn[:result]
      end
      allow(client).to receive(:messages).and_return(text_result("[]"))
      allow(ErrorNotifier).to receive(:notify)
      allow(Rails.logger).to receive(:warn)
      expect(api_client).to receive(:get).with("/products/product-a/custom_html", {}).once.and_return(
        { "success" => true, "custom_html" => "<main>Current</main>", "http_status" => 200 },
      )

      _first_events, first_turn = collect_events([{ role: "user", content: "Make the first change" }])
      _second_events, second_turn = collect_events([{ role: "user", content: "Make another change" }])

      expect(first_turn[:proposed_action]).to include(type: "api_write")
      expect(second_turn[:proposed_action]).to be_nil
      expect(captured_results.last["error"]).to include("successful full read", "in this turn")
      expect(turns).to be_empty
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

    it "discards a phantom staging claim from the UI and streams the honest line instead" do
      # The model says a change is staged but never called api_write, so no confirmation card will
      # render. The claim has already streamed to the seller, so the UI must be told to discard it
      # before the honest reply arrives — otherwise the false claim stays on screen.
      claim = "Staged. Confirm that card and the header updates."
      stub_stream_turns(
        { stream: [claim], result: text_result(claim) },
        { stream: [claim], result: text_result(claim) },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))

      events, result = collect_events([{ role: "user", content: "fix my header" }])

      event_names = events.map(&:first)
      fallback_index = events.index { |event, payload| event == :token && payload[:text] == described_class::NOTHING_STAGED_REPLY }
      expect(fallback_index).not_to be_nil
      expect(event_names.index(:reset)).to be < fallback_index
      expect(result[:reply]).to eq(described_class::NOTHING_STAGED_REPLY)
      expect(result[:proposed_action]).to be_nil
      expect(events.any? { |event, _| event == :proposed_action }).to be(false)
    end

    it "rejects untyped streamed text even when the prose backstop does not recognize it" do
      false_claim = "Your edit is waiting in the action panel. Use the button there."
      honest_reply = "I couldn't prepare that change. Please ask me to try again."
      stub_stream_turns(
        { stream: [false_claim], result: untyped_text_result(false_claim) },
        { stream: [honest_reply], result: text_result(honest_reply) },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))

      events, result = collect_events([{ role: "user", content: "fix my header" }])
      visible_reply = events.each_with_object(+"") do |(event, payload), text|
        text.clear if event == :reset
        text << payload[:text] if event == :token
      end

      expect(visible_reply).to eq(honest_reply)
      expect(result[:reply]).to eq(honest_reply)
      expect(result[:proposed_action]).to be_nil
    end

    it "finalizes the honest fallback before writing its terminal reset to the socket" do
      claim = "Staged. Confirm that card."
      stub_stream_turns(
        { stream: [claim], result: text_result(claim) },
        { stream: [claim], result: text_result(claim) },
      )

      completed_turns = []
      reset_count = 0
      emit = lambda do |event, _payload|
        next unless event == :reset

        reset_count += 1
        raise IOError, "socket closed" if reset_count == 2
      end

      expect do
        service.respond_streaming(
          messages: [{ role: "user", content: "fix my header" }],
          on_reply_complete: ->(turn) { completed_turns << turn },
          &emit
        )
      end.to raise_error(IOError, "socket closed")

      expect(completed_turns).to contain_exactly(
        {
          outcome: "reply_only",
          reply: described_class::NOTHING_STAGED_REPLY,
          proposed_action: nil,
          objects: [],
        },
      )
    end

    it "recovers a phantom staging claim by replaying the turn into a real proposal" do
      claim = "Staged. Confirm that card."
      write_turn = tool_result("api_write", {
                                 "endpoint" => "create_offer_code",
                                 "path_params" => { "link_id" => "p1" },
                                 "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
                               })
      stub_stream_turns(
        { stream: [claim], result: text_result(claim) },
        { stream: [], result: write_turn },
        {
          stream: ["Staged now — confirm the card."],
          result: text_result("Staged now — confirm the card.", outcome: "proposal_ready"),
        },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))

      events, result = collect_events([{ role: "user", content: "make a 20% code" }])

      expect(result[:reply]).to eq(described_class::PROPOSAL_READY_REPLY)
      expect(result[:proposed_action]).to include(type: "api_write")
      expect(events.any? { |event, _| event == :proposed_action }).to be(true)
    end

    it "recovers when the phantom claim arrives at the normal streaming iteration cap" do
      stub_const("#{described_class}::MAX_TOOL_ITERATIONS", 1)
      claim = "Staged. Confirm that card."
      write_turn = tool_result("api_write", {
                                 "endpoint" => "create_offer_code",
                                 "path_params" => { "link_id" => "p1" },
                                 "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
                               })
      stub_stream_turns(
        { stream: [claim], result: text_result(claim) },
        { stream: [], result: write_turn },
        {
          stream: ["Staged now — confirm the card."],
          result: text_result("Staged now — confirm the card.", outcome: "proposal_ready"),
        },
      )
      allow(client).to receive(:messages).and_return(text_result("[]"))

      events, result = collect_events([{ role: "user", content: "make a 20% code" }])

      expect(client).to have_received(:stream_messages)
        .exactly(described_class::MAX_TOOL_ITERATIONS + described_class::TURN_CONTRACT_RECOVERY_ITERATIONS).times
      reset_index = events.index { |event, _| event == :reset }
      recovered_reply_index = events.index { |event, payload| event == :token && payload[:text] == described_class::PROPOSAL_READY_REPLY }
      expect(reset_index).to be < recovered_reply_index
      expect(result[:reply]).to eq(described_class::PROPOSAL_READY_REPLY)
      expect(result[:proposed_action]).to include(type: "api_write")
      expect(events.any? { |event, _| event == :proposed_action }).to be(true)
    end
  end

  describe "SYSTEM_PROMPT_HEADER webhook guidance" do
    # Ping is not a general webhook replacement: User#ping_notification_targets only appends
    # notification_endpoint for the "sale" resource, so offering it for a cancellation or refund
    # webhook sends the creator to a screen that will never fire the event they asked for.
    let(:prompt) { described_class::SYSTEM_PROMPT_HEADER.gsub(/[[:space:]\u00a0]+/, " ") }

    # Every mention, not just one: a single qualified sentence elsewhere in the prompt would let an
    # unqualified "direct creators to Ping" be reintroduced with this spec still green.
    it "qualifies Ping as sales-only at every mention" do
      mentions = prompt.scan(/.{0,120}Settings > Advanced > Ping.{0,120}/)

      expect(mentions.size).to eq(1)
      mentions.each { expect(_1).to match(/SALES ONLY/) }
    end

    it "names the self-serve route that does cover the non-sale events" do
      expect(prompt).to include("cannot create webhooks")
      expect(prompt).to match(/Settings > Advanced > Applications/)
    end

    it "states the editor's product tag limits instead of leaving the model to guess" do
      expect(prompt).to include("dashboard product editor lets creators add up to 10 tags per product")
      expect(prompt).to include("each tag must be 2-20 characters")
      expect(prompt).to include("Existing products can have more tags")
      expect(prompt).to include("never state a different editor limit")
    end

    # The corpus has no webhook article, so the bullet cites this one by title for the app/token
    # steps. Redden if the prompt drops the citation or the article is renamed out from under it.
    it "cites a help article that exists in the shipped corpus" do
      expect(prompt).to include('"Create an application for the API"')
      expect(HelpCenter::Article.find_by(title: "Create an application for the API")).to be_present
    end
  end

  describe "model selection" do
    # These build the real client (the top-level `Ai::AnthropicClient.new` stub would swallow the
    # arguments this spec exists to pin), so re-stub .new to capture and return a double.
    let(:captured) { {} }

    before do
      allow(Ai::AnthropicClient).to receive(:new) do |**kwargs|
        captured.merge!(kwargs)
        client
      end
    end

    it "requests Grok with an Opus fallback when routing through OpenRouter" do
      allow(Ai::AnthropicClient).to receive(:openrouter_configured?).and_return(true)
      allow(client).to receive(:messages).and_return(text_result("hi"))

      service.respond(messages: [{ role: "user", content: "hello" }])

      expect(captured[:model]).to eq("x-ai/grok-4.5")
      expect(captured[:fallback_model]).to eq("anthropic/claude-opus-4.7")
    end

    it "keeps requesting Opus directly from Anthropic when OpenRouter is not configured" do
      allow(Ai::AnthropicClient).to receive(:openrouter_configured?).and_return(false)
      allow(client).to receive(:messages).and_return(text_result("hi"))

      service.respond(messages: [{ role: "user", content: "hello" }])

      expect(captured[:model]).to eq(Ai::AnthropicClient::DEFAULT_MODEL)
      expect(captured[:fallback_model]).to be_nil
    end
  end
end
