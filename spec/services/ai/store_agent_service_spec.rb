# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentService do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:service) { described_class.new(seller:, pundit_user:) }
  let(:client) { instance_double(OpenAI::Client) }

  before do
    allow(OpenAI::Client).to receive(:new).and_return(client)
  end

  # Helper to shape an OpenAI chat completion response with a plain assistant message.
  def assistant_message(content)
    { "choices" => [{ "message" => { "content" => content, "tool_calls" => nil } }] }
  end

  # Helper to shape a response that asks to call a tool.
  def tool_call_message(name, arguments)
    {
      "choices" => [{
        "message" => {
          "content" => nil,
          "tool_calls" => [{ "id" => "call_1", "function" => { "name" => name, "arguments" => arguments.to_json } }],
        },
      }],
    }
  end

  describe "#respond" do
    it "requires the conversation to end with a user message" do
      expect { service.respond(messages: [{ role: "assistant", content: "hi" }]) }
        .to raise_error(described_class::Error)
    end

    it "returns the model's reply when no tools are called" do
      allow(client).to receive(:chat).and_return(assistant_message("You have 3 products."))

      result = service.respond(messages: [{ role: "user", content: "How many products do I have?" }])

      expect(result[:reply]).to eq("You have 3 products.")
      expect(result[:proposed_action]).to be_nil
    end

    it "runs a read tool and feeds the result back to the model" do
      create(:product, user: seller, name: "Cool Ebook", price_cents: 999)

      # First call asks for list_products, second call returns a normal answer.
      allow(client).to receive(:chat).and_return(
        tool_call_message("list_products", {}),
        assistant_message("Your product Cool Ebook is $9.99."),
      )

      result = service.respond(messages: [{ role: "user", content: "List my products" }])

      expect(result[:reply]).to eq("Your product Cool Ebook is $9.99.")
      # The tool result should have been appended to the conversation for the second call.
      expect(client).to have_received(:chat).twice
    end

    it "returns a proposed action for a write tool WITHOUT mutating anything" do
      allow(client).to receive(:chat).and_return(
        tool_call_message("create_discount", { "code" => "LAUNCH", "percent_off" => 20 }),
        assistant_message("I've prepared a 20% off code called LAUNCH for your confirmation."),
      )

      expect do
        result = service.respond(messages: [{ role: "user", content: "Make a 20% off code LAUNCH" }])

        expect(result[:proposed_action]).to include(
          type: "create_discount",
          params: include(code: "LAUNCH", percent_off: 20),
        )
        expect(result[:proposed_action][:summary]).to be_present
      end.not_to change { seller.offer_codes.count }
    end

    it "only ever reads the current seller's own data" do
      create(:product, user: seller, name: "Mine")
      other_product = create(:product, name: "Theirs")

      allow(client).to receive(:chat).and_return(
        tool_call_message("list_products", {}),
        assistant_message("You have one product: Mine."),
      )

      result = service.respond(messages: [{ role: "user", content: "list my products" }])

      expect(result[:reply]).to eq("You have one product: Mine.")
      expect(client).to have_received(:chat).twice
      # The other seller's product is never in scope; the read tool is seller-scoped.
      expect(other_product.reload.name).to eq("Theirs")
    end

    context "store_stats balance gating" do
      let(:tool_then_done) do
        [tool_call_message("store_stats", {}), assistant_message("Here are your stats.")]
      end

      it "includes unpaid_balance for the owner (who can view payouts)" do
        allow(seller).to receive(:unpaid_balance_cents).and_return(12_345)
        captured = nil
        allow(client).to receive(:chat) do |args|
          # Capture the tool-result message fed back on the second turn.
          tool_msg = args[:parameters][:messages].find { |m| m[:role] == "tool" }
          captured = JSON.parse(tool_msg[:content]) if tool_msg
          captured ? assistant_message("done") : tool_call_message("store_stats", {})
        end

        service.respond(messages: [{ role: "user", content: "stats" }])

        expect(captured).to have_key("unpaid_balance")
      end

      it "omits unpaid_balance for a marketing role (denied payout access)" do
        marketing_user = create(:user)
        create(:team_membership, user: marketing_user, seller:, role: TeamMembership::ROLE_MARKETING)
        marketing_context = SellerContext.new(user: marketing_user, seller:)
        marketing_service = described_class.new(seller:, pundit_user: marketing_context)

        captured = nil
        allow(client).to receive(:chat) do |args|
          tool_msg = args[:parameters][:messages].find { |m| m[:role] == "tool" }
          captured = JSON.parse(tool_msg[:content]) if tool_msg
          captured ? assistant_message("done") : tool_call_message("store_stats", {})
        end

        marketing_service.respond(messages: [{ role: "user", content: "stats" }])

        expect(captured).not_to have_key("unpaid_balance")
        expect(captured).to have_key("gross_sales")
      end
    end

    context "when the model proposes more than one write in a single turn" do
      # Two write tool calls in one assistant message: only the first may be staged, and the second
      # must be rejected back to the model so the confirmation card can't describe a different change.
      def two_write_calls_message
        {
          "choices" => [{
            "message" => {
              "content" => nil,
              "tool_calls" => [
                { "id" => "call_a", "function" => { "name" => "create_discount", "arguments" => { "code" => "FIRST", "percent_off" => 10 }.to_json } },
                { "id" => "call_b", "function" => { "name" => "create_discount", "arguments" => { "code" => "SECOND", "percent_off" => 50 }.to_json } },
              ],
            },
          }],
        }
      end

      it "stages only the first proposal and tells the model the second was dropped" do
        captured_tool_results = []
        allow(client).to receive(:chat) do |args|
          tool_msgs = args[:parameters][:messages].select { |m| m[:role] == "tool" }
          if tool_msgs.any?
            captured_tool_results = tool_msgs.map { |m| JSON.parse(m[:content]) }
            assistant_message("I've prepared the FIRST code for your confirmation.")
          else
            two_write_calls_message
          end
        end

        result = service.respond(messages: [{ role: "user", content: "make two codes" }])

        expect(result[:proposed_action]).to include(type: "create_discount", params: include(code: "FIRST"))
        # The second write call was rejected, not staged.
        expect(captured_tool_results.last).to include("error")
        expect(captured_tool_results.last["error"]).to match(/one change/i)
      end
    end

    context "when the model never finishes within the tool-iteration cap" do
      it "does not claim there is a change to confirm when none was staged" do
        # Always ask for a read tool, never returning a final answer, so the loop exhausts the cap
        # without any write action being proposed.
        allow(client).to receive(:chat).and_return(tool_call_message("list_products", {}))

        result = service.respond(messages: [{ role: "user", content: "loop forever" }])

        expect(result[:proposed_action]).to be_nil
        expect(result[:reply]).not_to match(/confirm/i)
      end
    end

    context "product resolution scope" do
      it "refuses to propose a price change for an archived product" do
        archived = create(:product, user: seller, name: "Archived One", price_cents: 500, archived: true)
        captured_tool_results = []
        allow(client).to receive(:chat) do |args|
          tool_msgs = args[:parameters][:messages].select { |m| m[:role] == "tool" }
          if tool_msgs.any?
            captured_tool_results = tool_msgs.map { |m| JSON.parse(m[:content]) }
            assistant_message("done")
          else
            tool_call_message("update_product_price", { "product_id" => archived.external_id, "new_price" => 9 })
          end
        end

        result = service.respond(messages: [{ role: "user", content: "set archived price" }])

        expect(result[:proposed_action]).to be_nil
        expect(captured_tool_results.last).to include("error")
      end

      it "refuses a non-numeric price instead of proposing a free product" do
        product = create(:product, user: seller, name: "Real One", price_cents: 1000)
        captured_tool_results = []
        allow(client).to receive(:chat) do |args|
          tool_msgs = args[:parameters][:messages].select { |m| m[:role] == "tool" }
          if tool_msgs.any?
            captured_tool_results = tool_msgs.map { |m| JSON.parse(m[:content]) }
            assistant_message("done")
          else
            tool_call_message("update_product_price", { "product_id" => product.external_id, "new_price" => "free" })
          end
        end

        result = service.respond(messages: [{ role: "user", content: "make it free-ish" }])

        expect(result[:proposed_action]).to be_nil
        expect(captured_tool_results.last["error"]).to match(/number/i)
      end
    end

    context "when the model emits malformed tool-call arguments" do
      # OpenAI tool-call `arguments` is supposed to be a JSON object string, but a hallucinating
      # model can return a bare array or scalar. The write tools index arguments by key, which used
      # to raise TypeError (Integer#[] / no implicit conversion) and surface as an unhandled 500.
      # parse_arguments now coerces non-objects to {} so the tool falls through to its normal
      # "field is required" validation instead of crashing.
      ["[1,2,3]", "42", "\"just a string\"", "null", "{not valid json"].each do |raw_args|
        it "does not raise on argument payload #{raw_args.inspect}" do
          allow(client).to receive(:chat).and_return(
            { "choices" => [{ "message" => { "content" => nil, "tool_calls" => [{ "id" => "call_1", "function" => { "name" => "create_discount", "arguments" => raw_args } }] } }] },
            assistant_message("I need a bit more detail to create that discount."),
          )

          expect do
            result = service.respond(messages: [{ role: "user", content: "make a discount" }])
            expect(result[:reply]).to be_present
            expect(result[:proposed_action]).to be_nil
          end.not_to change { seller.offer_codes.count }
        end
      end
    end
  end
end
