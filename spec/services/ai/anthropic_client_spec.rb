# frozen_string_literal: true

require "spec_helper"

describe Ai::AnthropicClient do
  subject(:client) { described_class.new(timeout: 5) }

  let(:url) { "https://api.anthropic.com/v1/messages" }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("ANTHROPIC_API_KEY").and_return("sk-ant-test")
  end

  describe "#messages" do
    it "sends the system prompt, messages, and tools, and returns the assistant text" do
      body = { "content" => [{ "type" => "text", "text" => "You have 3 products." }], "stop_reason" => "end_turn" }
      stub = stub_request(:post, url)
        .with(
          headers: { "x-api-key" => "sk-ant-test", "anthropic-version" => "2023-06-01" },
          body: hash_including("model" => described_class::DEFAULT_MODEL, "system" => "be helpful", "stream" => false),
        )
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "be helpful", messages: [{ role: "user", content: "how many products" }], tools: [{ name: "api_read" }])

      expect(stub).to have_been_requested
      expect(result.text).to eq("You have 3 products.")
      expect(result.tool_uses).to eq([])
      expect(result.stop_reason).to eq("end_turn")
    end

    it "parses tool_use blocks with their input" do
      body = {
        "content" => [
          { "type" => "text", "text" => "Let me look that up." },
          { "type" => "tool_use", "id" => "toolu_1", "name" => "api_read", "input" => { "endpoint" => "list_products" } },
        ],
        "stop_reason" => "tool_use",
      }
      stub_request(:post, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "s", messages: [{ role: "user", content: "list" }])

      expect(result.text).to eq("Let me look that up.")
      expect(result.tool_uses).to eq([{ id: "toolu_1", name: "api_read", input: { "endpoint" => "list_products" } }])
    end

    it "raises Error on a non-success status" do
      stub_request(:post, url).to_return(status: 500, body: "boom")

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /failed/i)
    end
  end

  describe "API key resolution" do
    it "uses ANTHROPIC_API_KEY when it is set" do
      allow(GlobalConfig).to receive(:get).with("ANTHROPIC_API_KEY").and_return("sk-ant-dedicated")

      stub = stub_request(:post, url)
        .with(headers: { "x-api-key" => "sk-ant-dedicated" })
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
    end

    it "falls back to WALKS_ANTHROPIC_API_KEY when ANTHROPIC_API_KEY is blank" do
      allow(GlobalConfig).to receive(:get).with("ANTHROPIC_API_KEY").and_return("")
      allow(GlobalConfig).to receive(:get).with("WALKS_ANTHROPIC_API_KEY").and_return("sk-ant-walks")

      stub = stub_request(:post, url)
        .with(headers: { "x-api-key" => "sk-ant-walks" })
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
    end

    it "raises a clear error (no blank-key request) when both keys are missing" do
      allow(GlobalConfig).to receive(:get).with("ANTHROPIC_API_KEY").and_return("")
      allow(GlobalConfig).to receive(:get).with("WALKS_ANTHROPIC_API_KEY").and_return(nil)
      request = stub_request(:post, url)

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /not configured/i)
      expect(request).not_to have_been_requested
    end
  end

  describe "#stream_messages" do
    # Build a raw Anthropic SSE body from a list of [event, data] pairs.
    def sse(*events)
      events.map { |event, data| "event: #{event}\ndata: #{data.to_json}\n\n" }.join
    end

    it "yields text deltas as they arrive and returns the assembled text" do
      stream = sse(
        ["message_start", { type: "message_start" }],
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "You have " } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "3 products." } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "end_turn" } }],
        ["message_stop", { type: "message_stop" }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      chunks = []
      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "products" }]) { |text| chunks << text }

      expect(chunks).to eq(["You have ", "3 products."])
      expect(result.text).to eq("You have 3 products.")
      expect(result.stop_reason).to eq("end_turn")
      expect(result.tool_uses).to eq([])
    end

    it "assembles a streamed tool_use block from its input_json_delta fragments" do
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_9", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"create_' } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: 'offer_code"}' } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "make a code" }])

      expect(result.tool_uses).to eq([{ id: "toolu_9", name: "api_write", input: { "endpoint" => "create_offer_code" } }])
      expect(result.stop_reason).to eq("tool_use")
    end

    it "raises an error for malformed streamed tool_use input" do
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_read" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{not json" } }],
        ["content_block_stop", { index: 0 }],
      )
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /unreadable tool call/i)
    end

    it "raises Error on a stream-level error event" do
      stream = sse(["error", { error: { message: "overloaded" } }])
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /overloaded/i)
    end
  end
end
