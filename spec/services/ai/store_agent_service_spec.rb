# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentService do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:service) { described_class.new(seller:, pundit_user:) }
  let(:client) { instance_double(OpenAI::Client) }
  # The service reaches the real v2 API through StoreAgentApiClient; stub it so these stay fast unit
  # tests of the tool-dispatch + propose/confirm logic (the executor spec covers the real API path).
  let(:api_client) { instance_double(Ai::StoreAgentApiClient) }

  before do
    allow(OpenAI::Client).to receive(:new).and_return(client)
    allow(Ai::StoreAgentApiClient).to receive(:new).and_return(api_client)
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

    describe "api_read" do
      it "runs a read endpoint against the API and feeds the result back to the model" do
        expect(api_client).to receive(:get).with("/products", {}).and_return(
          { "success" => true, "products" => [{ "id" => "p1", "name" => "Cool Ebook", "formatted_price" => "$9.99", "published" => true }], "http_status" => 200 },
        )
        allow(client).to receive(:chat).and_return(
          tool_call_message("api_read", { "endpoint" => "list_products" }),
          assistant_message("Your product Cool Ebook is $9.99."),
        )

        result = service.respond(messages: [{ role: "user", content: "List my products" }])

        expect(result[:reply]).to eq("Your product Cool Ebook is $9.99.")
        expect(client).to have_received(:chat).twice
        # The product is surfaced as a display object for the chat to render inline as a card.
        expect(result[:objects]).to include(include(type: "product", title: "Cool Ebook"))
      end

      it "expands path params into the endpoint path" do
        expect(api_client).to receive(:get).with("/products/abc123", {}).and_return({ "success" => true, "http_status" => 200 })
        allow(client).to receive(:chat).and_return(
          tool_call_message("api_read", { "endpoint" => "get_product", "path_params" => { "id" => "abc123" } }),
          assistant_message("Here is that product."),
        )

        service.respond(messages: [{ role: "user", content: "show product abc123" }])
      end

      it "rejects an unknown endpoint id without calling the API" do
        expect(api_client).not_to receive(:get)
        captured = nil
        allow(client).to receive(:chat) do |args|
          tool_msg = args[:parameters][:messages].find { |m| m[:role] == "tool" }
          captured = JSON.parse(tool_msg[:content]) if tool_msg
          captured ? assistant_message("ok") : tool_call_message("api_read", { "endpoint" => "drop_tables" })
        end

        service.respond(messages: [{ role: "user", content: "hack" }])

        expect(captured).to include("error")
      end

      it "refuses to run a WRITE endpoint through api_read (it must be confirmed)" do
        expect(api_client).not_to receive(:get)
        captured = nil
        allow(client).to receive(:chat) do |args|
          tool_msg = args[:parameters][:messages].find { |m| m[:role] == "tool" }
          captured = JSON.parse(tool_msg[:content]) if tool_msg
          captured ? assistant_message("ok") : tool_call_message("api_read", { "endpoint" => "refund_sale", "path_params" => { "id" => "1" } })
        end

        service.respond(messages: [{ role: "user", content: "refund it now" }])

        expect(captured["error"]).to match(/confirm/i)
      end

      it "surfaces a missing path param as an error instead of raising" do
        expect(api_client).not_to receive(:get)
        captured = nil
        allow(client).to receive(:chat) do |args|
          tool_msg = args[:parameters][:messages].find { |m| m[:role] == "tool" }
          captured = JSON.parse(tool_msg[:content]) if tool_msg
          captured ? assistant_message("ok") : tool_call_message("api_read", { "endpoint" => "get_product" })
        end

        service.respond(messages: [{ role: "user", content: "show the product" }])

        expect(captured["error"]).to match(/missing path parameter/i)
      end
    end

    describe "api_write" do
      it "returns a proposed action WITHOUT mutating or calling the API" do
        expect(api_client).not_to receive(:write)
        allow(client).to receive(:chat).and_return(
          tool_call_message("api_write", {
                              "endpoint" => "create_offer_code",
                              "path_params" => { "link_id" => "prod_1" },
                              "params" => { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
                            }),
          assistant_message("I've prepared a 20% off code called LAUNCH for your confirmation."),
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
      end

      it "rejects a READ endpoint sent to api_write (nudges to api_read)" do
        captured = nil
        allow(client).to receive(:chat) do |args|
          tool_msg = args[:parameters][:messages].find { |m| m[:role] == "tool" }
          captured = JSON.parse(tool_msg[:content]) if tool_msg
          captured ? assistant_message("ok") : tool_call_message("api_write", { "endpoint" => "list_products" })
        end

        result = service.respond(messages: [{ role: "user", content: "change products" }])

        expect(result[:proposed_action]).to be_nil
        expect(captured["error"]).to match(/api_read/i)
      end

      it "validates path params at propose time so a missing id can't reach the executor" do
        captured = nil
        allow(client).to receive(:chat) do |args|
          tool_msg = args[:parameters][:messages].find { |m| m[:role] == "tool" }
          captured = JSON.parse(tool_msg[:content]) if tool_msg
          captured ? assistant_message("ok") : tool_call_message("api_write", { "endpoint" => "refund_sale", "params" => { "amount_cents" => 100 } })
        end

        result = service.respond(messages: [{ role: "user", content: "refund" }])

        expect(result[:proposed_action]).to be_nil
        expect(captured["error"]).to match(/missing path parameter/i)
      end
    end

    context "when the model proposes more than one write in a single turn" do
      def two_write_calls_message
        {
          "choices" => [{
            "message" => {
              "content" => nil,
              "tool_calls" => [
                { "id" => "call_a", "function" => { "name" => "api_write", "arguments" => { "endpoint" => "create_offer_code", "path_params" => { "link_id" => "p1" }, "params" => { "name" => "FIRST", "amount_off" => 10, "offer_type" => "percent" } }.to_json } },
                { "id" => "call_b", "function" => { "name" => "api_write", "arguments" => { "endpoint" => "create_offer_code", "path_params" => { "link_id" => "p1" }, "params" => { "name" => "SECOND", "amount_off" => 50, "offer_type" => "percent" } }.to_json } },
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

        expect(result[:proposed_action]).to include(type: "api_write", params: include("params" => include("name" => "FIRST")))
        expect(captured_tool_results.last).to include("error")
        expect(captured_tool_results.last["error"]).to match(/one change/i)
      end
    end

    context "when the model never finishes within the tool-iteration cap" do
      it "does not claim there is a change to confirm when none was staged" do
        allow(api_client).to receive(:get).and_return({ "success" => true, "http_status" => 200 })
        allow(client).to receive(:chat).and_return(tool_call_message("api_read", { "endpoint" => "list_products" }))

        result = service.respond(messages: [{ role: "user", content: "loop forever" }])

        expect(result[:proposed_action]).to be_nil
        expect(result[:reply]).not_to match(/confirm/i)
      end
    end

    context "when the model emits malformed tool-call arguments" do
      # OpenAI tool-call `arguments` is supposed to be a JSON object string, but a hallucinating model
      # can return a bare array or scalar. parse_arguments coerces non-objects to {} so the tool
      # falls through to its normal "endpoint is required" handling instead of raising a 500.
      ["[1,2,3]", "42", "\"just a string\"", "null", "{not valid json"].each do |raw_args|
        it "does not raise on argument payload #{raw_args.inspect}" do
          allow(client).to receive(:chat).and_return(
            { "choices" => [{ "message" => { "content" => nil, "tool_calls" => [{ "id" => "call_1", "function" => { "name" => "api_write", "arguments" => raw_args } }] } }] },
            assistant_message("I need a bit more detail to make that change."),
          )

          expect do
            result = service.respond(messages: [{ role: "user", content: "make a change" }])
            expect(result[:reply]).to be_present
            expect(result[:proposed_action]).to be_nil
          end.not_to change { seller.offer_codes.count }
        end
      end
    end
  end
end
