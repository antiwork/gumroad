# frozen_string_literal: true

require "spec_helper"

describe Ai::AnthropicClient do
  subject(:client) { described_class.new(timeout: 5) }

  let(:url) { "https://api.anthropic.com/v1/messages" }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("ANTHROPIC_API_KEY").and_return("sk-ant-test")
    # Pin OpenRouter routing OFF by default so these specs exercise the direct-to-Anthropic path
    # regardless of what the host machine's environment has configured.
    allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return(nil)
  end

  describe "#messages" do
    it "sends the system prompt, messages, and tools, and returns the assistant text" do
      body = { "content" => [{ "type" => "text", "text" => "You have 3 products." }], "stop_reason" => "end_turn" }
      stub = stub_request(:post, url)
        .with(
          headers: { "x-api-key" => "sk-ant-test", "anthropic-version" => "2023-06-01" },
          body: hash_including("model" => described_class::DEFAULT_MODEL, "stream" => false),
        )
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "be helpful", messages: [{ role: "user", content: "how many products" }], tools: [{ name: "api_read" }])

      expect(stub).to have_been_requested
      expect(result.text).to eq("You have 3 products.")
      expect(result.tool_uses).to eq([])
      expect(result.stop_reason).to eq("end_turn")
    end

    it "reports how many output tokens the turn cost, so a caller can bound a whole request" do
      # The store agent's tool loop makes up to 25 calls on one client. Per-call max_tokens bounds
      # one turn; the running total this exposes is what bounds the request as a whole.
      body = {
        "content" => [{ "type" => "text", "text" => "You have 3 products." }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 900, "output_tokens" => 1_234 },
      }
      stub_request(:post, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "be helpful", messages: [{ role: "user", content: "how many products" }])

      expect(result.output_tokens).to eq(1_234)
    end

    it "estimates the turn's size when the provider reports no usage, rather than reporting nothing" do
      # A nil here would read as "this turn was free" and silently disable the caller's spending
      # bound for the rest of the request, so an approximate number is the safer answer. Most of a
      # page-authoring turn lives inside the tool call's arguments, so those count too.
      page_html = "<html>#{"x" * 4_000}</html>"
      body = {
        "content" => [{ "type" => "tool_use", "id" => "toolu_1", "name" => "api_write", "input" => { "html" => page_html } }],
        "stop_reason" => "tool_use",
      }
      stub_request(:post, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "be helpful", messages: [{ role: "user", content: "build my page" }])

      expect(result.output_tokens).to be > 900
      expect(result.output_tokens).to be < 2_000
    end

    it "marks the system prompt and the last tool as cacheable so Anthropic can reuse the shared prefix" do
      captured = nil
      stub_request(:post, url)
        .with { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(
        system: "be helpful",
        messages: [{ role: "user", content: "x" }],
        tools: [{ name: "api_read" }, { name: "api_write" }],
      )

      expect(captured["system"]).to eq([{ "type" => "text", "text" => "be helpful", "cache_control" => { "type" => "ephemeral" } }])
      expect(captured["tools"][0]).not_to have_key("cache_control")
      expect(captured["tools"][1]["cache_control"]).to eq("type" => "ephemeral")
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
      stub_request(:post, url).to_return(status: 400, body: "boom")

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /failed/i)
    end
  end

  describe "retries" do
    before { allow(client).to receive(:sleep) } # keep specs fast; retry delays are exercised via the stub

    it "retries a buffered request on a retryable status and succeeds" do
      body = { "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }
      stub_request(:post, url)
        .to_return({ status: 529, body: { error: { type: "overloaded_error", message: "Overloaded" } }.to_json },
                   { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(result.text).to eq("ok")
      expect(client).to have_received(:sleep).once
    end

    it "retries a network timeout and surfaces TransientError after exhausting attempts" do
      stub_request(:post, url).to_timeout

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::TransientError, /network error/i)
      expect(client).to have_received(:sleep).twice # MAX_ATTEMPTS - 1 backoffs
    end

    it "does not retry a deterministic failure like a 400" do
      stub = stub_request(:post, url).to_return(status: 400, body: { error: { message: "bad request" } }.to_json)

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /bad request/)
      expect(stub).to have_been_requested.once
    end

    it "sleeps the Retry-After header value on a 429 instead of the default backoff" do
      body = { "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }
      stub_request(:post, url)
        .to_return({ status: 429, body: { error: { type: "rate_limit_error", message: "rate limited" } }.to_json, headers: { "Retry-After" => "4" } },
                   { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(result.text).to eq("ok")
      expect(client).to have_received(:sleep).with(4.0)
    end

    it "gives up instead of sleeping when Retry-After exceeds the retry sleep budget" do
      # A long server-mandated wait would block the calling (Rack request) thread; surfacing the
      # failure immediately is better than holding the request hostage.
      stub = stub_request(:post, url)
        .to_return(status: 429, body: { error: { type: "rate_limit_error", message: "rate limited" } }.to_json, headers: { "Retry-After" => "30" })

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::TransientError, /rate limited/)
      expect(stub).to have_been_requested.once
      expect(client).not_to have_received(:sleep)
    end

    it "caps total retry sleep across calls on the same client instance" do
      # The agent's tool loop chains several buffered calls on one client inside a single web
      # request; the shared budget keeps repeated transient failures from stacking up blocked time.
      failure = { status: 529, body: { error: { type: "overloaded_error", message: "Overloaded" } }.to_json }
      success = { status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" } }
      stub_request(:post, url).to_return(failure, success, failure, success, failure, failure)

      slept = 0.0
      allow(client).to receive(:sleep) { |seconds| slept += seconds }

      2.times { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) } # 1s + 1s spent
      expect { 3.times { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) } }
        .to raise_error(described_class::TransientError)

      expect(slept).to be <= described_class::RETRY_SLEEP_BUDGET_IN_SECONDS
    end

    it "retries a streaming request that fails before any output reached the caller" do
      good_stream = "event: content_block_start\ndata: #{{ index: 0, content_block: { type: "text" } }.to_json}\n\n" \
                    "event: content_block_delta\ndata: #{{ index: 0, delta: { type: "text_delta", text: "hi" } }.to_json}\n\n" \
                    "event: message_delta\ndata: #{{ delta: { stop_reason: "end_turn" } }.to_json}\n\n"
      stub_request(:post, url)
        .to_return({ status: 529, body: { error: { type: "overloaded_error", message: "Overloaded" } }.to_json },
                   { status: 200, body: good_stream, headers: { "Content-Type" => "text/event-stream" } })

      chunks = []
      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text }

      expect(chunks).to eq(["hi"])
      expect(result.text).to eq("hi")
    end

    it "does not retry a stream that already yielded output to the caller" do
      # The first token has already rendered on the seller's screen when the overload event arrives;
      # replaying the request would restart the reply mid-sentence, so the failure must surface.
      broken_stream = "event: content_block_start\ndata: #{{ index: 0, content_block: { type: "text" } }.to_json}\n\n" \
                      "event: content_block_delta\ndata: #{{ index: 0, delta: { type: "text_delta", text: "partial" } }.to_json}\n\n" \
                      "event: error\ndata: #{{ error: { type: "overloaded_error", message: "Overloaded" } }.to_json}\n\n"
      stub = stub_request(:post, url).to_return(status: 200, body: broken_stream, headers: { "Content-Type" => "text/event-stream" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| } }
        .to raise_error(described_class::TransientError, /overloaded/i)
      expect(stub).to have_been_requested.once
    end
  end

  describe "timeouts" do
    it "uses per-operation timeouts with the configured value as the read (silence) timeout" do
      # A per-operation read timeout bounds silence between chunks, not total stream duration — the
      # old single global timeout killed healthy long generations mid-stream.
      chain = HTTP.timeout(connect: 1) # any chainable; we only assert what the client requests
      allow(HTTP).to receive(:timeout).and_return(chain)
      allow(chain).to receive(:headers).and_call_original

      stub_request(:post, url).to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })
      described_class.new(timeout: 45).messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(HTTP).to have_received(:timeout).with(
        connect: described_class::CONNECT_TIMEOUT_IN_SECONDS,
        write: described_class::WRITE_TIMEOUT_IN_SECONDS,
        read: 45,
      )
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

  describe "OpenRouter gateway routing" do
    let(:openrouter_url) { "https://openrouter.ai/api/v1/messages" }

    before do
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_FALLBACK_MODEL").and_return(nil)
    end

    it "routes requests to OpenRouter with its key and a GPT fallback when OPENROUTER_API_KEY is set" do
      captured = nil
      stub = stub_request(:post, openrouter_url)
        .with(headers: { "x-api-key" => "sk-or-test", "anthropic-version" => "2023-06-01" }) { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
      expect(result.text).to eq("ok")
      expect(captured["model"]).to eq(described_class::DEFAULT_MODEL)
      expect(captured["fallbacks"]).to eq([{ "model" => described_class::DEFAULT_FALLBACK_MODEL }])
    end

    it "streams through OpenRouter with the same Anthropic SSE protocol" do
      stream = "event: content_block_start\ndata: #{{ index: 0, content_block: { type: "text" } }.to_json}\n\n" \
               "event: content_block_delta\ndata: #{{ index: 0, delta: { type: "text_delta", text: "hi" } }.to_json}\n\n" \
               "event: message_delta\ndata: #{{ delta: { stop_reason: "end_turn" } }.to_json}\n\n"
      stub = stub_request(:post, openrouter_url)
        .with(body: hash_including("stream" => true, "fallbacks" => [{ "model" => described_class::DEFAULT_FALLBACK_MODEL }]))
        .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      chunks = []
      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text }

      expect(stub).to have_been_requested
      expect(chunks).to eq(["hi"])
      expect(result.stop_reason).to eq("end_turn")
    end

    it "honors an OPENROUTER_FALLBACK_MODEL override" do
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_FALLBACK_MODEL").and_return("openai/gpt-4o")
      captured = nil
      stub_request(:post, openrouter_url)
        .with { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(captured["fallbacks"]).to eq([{ "model" => "openai/gpt-4o" }])
    end

    it "retries OpenRouter's 408 upstream-timeout status like other transient failures" do
      allow(client).to receive(:sleep)
      body = { "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }
      stub_request(:post, openrouter_url)
        .to_return({ status: 408, body: { error: { code: 408, message: "Your request timed out" } }.to_json },
                   { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(result.text).to eq("ok")
      expect(client).to have_received(:sleep).once
    end

    it "treats a 200 response carrying an error body as a failure instead of a blank reply" do
      # OpenRouter returns HTTP 200 with an error object when the failure happened after the
      # upstream model started processing; a transient error type there gets retried like any other.
      allow(client).to receive(:sleep)
      good = { "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }
      stub_request(:post, openrouter_url)
        .to_return({ status: 200, body: { error: { type: "overloaded_error", message: "Overloaded" } }.to_json, headers: { "Content-Type" => "application/json" } },
                   { status: 200, body: good.to_json, headers: { "Content-Type" => "application/json" } })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(result.text).to eq("ok")
      expect(client).to have_received(:sleep).once
    end

    it "does not send fallbacks or touch OpenRouter when the key is not configured" do
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("")
      captured = nil
      stub = stub_request(:post, url)
        .with(headers: { "x-api-key" => "sk-ant-test" }) { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
      expect(captured).not_to have_key("fallbacks")
    end

    describe "served-model logging" do
      before { allow(Rails.logger).to receive(:warn) }

      it "warns when a buffered response was served by a different model than requested" do
        body = { "model" => "openai/gpt-5", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }
        stub_request(:post, openrouter_url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

        client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(Rails.logger).to have_received(:warn).with(/served by fallback model openai\/gpt-5 \(requested #{described_class::DEFAULT_MODEL}\)/o)
      end

      it "warns when a stream's message_start names a different model than requested" do
        stream = "event: message_start\ndata: #{{ message: { model: "openai/gpt-5" } }.to_json}\n\n" \
                 "event: content_block_start\ndata: #{{ index: 0, content_block: { type: "text" } }.to_json}\n\n" \
                 "event: content_block_delta\ndata: #{{ index: 0, delta: { type: "text_delta", text: "hi" } }.to_json}\n\n" \
                 "event: message_delta\ndata: #{{ delta: { stop_reason: "end_turn" } }.to_json}\n\n"
        stub_request(:post, openrouter_url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

        client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| }

        expect(Rails.logger).to have_received(:warn).with(/served by fallback model openai\/gpt-5/)
      end

      it "does not warn when the served model is the requested one restyled by the provider" do
        # OpenRouter reports the model as "anthropic/claude-opus-4.7" (provider prefix, dotted
        # version) for a request naming "claude-opus-4-7" — same model, so no warning. Verified
        # against the live endpoint 2026-07-13.
        body = { "model" => "anthropic/#{described_class::DEFAULT_MODEL.tr("-", ".")}", "content" => [], "stop_reason" => "end_turn" }
        stub_request(:post, openrouter_url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

        client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(Rails.logger).not_to have_received(:warn)
      end
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

    it "reports the stream's output token usage, which arrives on the final message_delta" do
      # A stream reports usage at the end rather than up front, so the store agent can only add a
      # streamed turn to its request-wide budget once the turn is complete.
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "done" } }],
        ["message_delta", { delta: { stop_reason: "end_turn" }, usage: { output_tokens: 5_678 } }],
        ["message_stop", { type: "message_stop" }],
      )
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "products" }]) { |_text| }

      expect(result.output_tokens).to eq(5_678)
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

    it "retries when a completed turn delivers unreadable tool_use input, and succeeds on the re-request" do
      # Production traffic flows through OpenRouter's gateway, which can drop input_json_delta
      # fragments while still delivering the closing stop_reason — the turn looks complete but the
      # tool call's JSON is cut off mid-object. That's transport corruption, not the model
      # misbehaving, so the client should re-request the turn instead of failing it.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      complete = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product"}' } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .to_return({ status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" } },
                   { status: 200, body: complete, headers: { "Content-Type" => "text/event-stream" } })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(result.tool_uses).to eq([{ id: "toolu_x", name: "api_write", input: { "endpoint" => "update_product" } }])
      expect(client).to have_received(:sleep).once
    end

    it "falls back to a single non-streamed request when every streamed attempt delivers an unreadable tool call" do
      # OpenRouter's gateway occasionally loses input_json_delta fragments on EVERY streamed
      # attempt (seen in production across multiple hosts) — retrying the stream re-rolls the same
      # lossy channel. A buffered response arrives as one body and can't lose fragments, so the
      # client replays the request once without streaming instead of failing the seller's turn.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      streamed = stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered_body = {
        "content" => [{ "type" => "tool_use", "id" => "toolu_y", "name" => "api_write", "input" => { "endpoint" => "update_product" } }],
        "stop_reason" => "tool_use",
      }
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 200, body: buffered_body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(streamed).to have_been_requested.times(3)
      expect(buffered).to have_been_requested.once
      expect(result.tool_uses).to eq([{ id: "toolu_y", name: "api_write", input: { "endpoint" => "update_product" } }])
      expect(result.stop_reason).to eq("tool_use")
    end

    it "replays with the caller's buffered budget, not its streaming one" do
      # The replay is a buffered generation on the request thread, so it is bounded by wall clock
      # rather than by silence between chunks. A caller whose streaming cap is sized for a long
      # artifact must be able to hand the replay a smaller cap, or the recovery becomes the timeout
      # it exists to avoid.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{broken" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false, "max_tokens" => 4_000))
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "done" }], "stop_reason" => "end_turn" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 40_000, buffered_max_tokens: 4_000)

      expect(buffered).to have_been_requested.once
    end

    it "replays with what the call has left when the caller draws no distinction" do
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{broken" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 1_000 } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      # No buffered cap was passed, so the replay falls back to the streaming one — less the 3,000
      # tokens the three discarded attempts already generated against the same call.
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false, "max_tokens" => 37_000))
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "done" }], "stop_reason" => "end_turn" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 40_000)

      expect(buffered).to have_been_requested.once
    end

    it "never generates more than the caller's allowance across its retries and its replay" do
      # One call can generate the turn four times over: three streamed attempts whose tool call
      # arrives corrupted, then the buffered replay. If each of those got a fresh `max_tokens`, a
      # caller that thought it had authorized 32,000 tokens would be billed for up to 128,000 —
      # and a cumulative budget built on top of this cap (the store agent's per-request ceiling)
      # would be nominal rather than real. Each attempt is capped at what the call has left.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_user_custom_html","params":{"custom_html":"<div>cut off' } }],
        ["message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 10_000 } }],
      )
      streamed = stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered_body = {
        "content" => [{ "type" => "tool_use", "id" => "toolu_y", "name" => "api_write", "input" => { "endpoint" => "update_user_custom_html" } }],
        "stop_reason" => "tool_use",
        "usage" => { "output_tokens" => 1_500 },
      }
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false, "max_tokens" => 2_000))
        .to_return(status: 200, body: buffered_body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 32_000)

      expect(streamed).to have_been_requested.times(3)
      expect(buffered).to have_been_requested.once
      # Every generation is charged to the call, and the total stays inside what the caller allowed.
      expect(result.output_tokens).to eq(31_500)
      expect(result.output_tokens).to be <= 32_000
    end

    it "asks each streamed retry only for what the call has left" do
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{broken" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 10_000 } }],
      )
      requested_caps = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requested_caps << body["max_tokens"] if body["stream"]
        if body["stream"]
          { status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" } }
        else
          { status: 200, body: { "content" => [{ "type" => "text", "text" => "done" }], "stop_reason" => "end_turn", "usage" => { "output_tokens" => 100 } }.to_json,
            headers: { "Content-Type" => "application/json" } }
        end
      end

      client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 32_000)

      expect(requested_caps).to eq([32_000, 22_000, 12_000])
    end

    it "surfaces the original failure instead of replaying once the discarded attempts have spent the allowance" do
      # A replay squeezed into what's left of an exhausted allowance would stop at max_tokens
      # mid-answer and be thrown away in turn, so it would cost the seller another billed
      # generation and still fail. Fail with the honest error instead.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{broken" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 7_900 } }],
      )
      streamed = stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered = stub_request(:post, url).with(body: hash_including("stream" => false))

      expect do
        client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 8_000)
      end.to raise_error(Ai::AnthropicClient::UnreadableToolCallError)

      # The first attempt spent all but 100 tokens, so neither a retry nor a replay is worth making.
      expect(streamed).to have_been_requested.once
      expect(buffered).not_to have_been_made
    end

    it "counts what the discarded streamed attempts generated on top of the replay's own usage" do
      # The failed attempts were generated and billed before we found out their tool call was
      # unreadable, and the replay regenerates the turn from scratch. A caller bounding how much one
      # request may generate has to see all of it — reporting only the replay would let a request
      # that burned three page-sized turns look like it spent one, and walk straight past its
      # ceiling.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_user_custom_html","params":{"custom_html":"<div>cut off' } }],
        ["message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 6_000 } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered_body = {
        "content" => [{ "type" => "tool_use", "id" => "toolu_y", "name" => "api_write", "input" => { "endpoint" => "update_user_custom_html" } }],
        "stop_reason" => "tool_use",
        "usage" => { "output_tokens" => 8_000 },
      }
      stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 200, body: buffered_body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 32_000)

      # Three streamed attempts at 6,000 each, then the 8,000-token replay.
      expect(result.output_tokens).to eq(26_000)
    end

    it "counts what a retried streamed attempt generated on top of the attempt that succeeded" do
      # Same reasoning one step earlier in the recovery: when a corrupted attempt is followed by a
      # clean re-request rather than a buffered replay, the corrupted one still generated output.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
        ["message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 12_000 } }],
      )
      complete = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product"}' } }],
        ["message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 900 } }],
      )
      stub_request(:post, url)
        .to_return({ status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" } },
                   { status: 200, body: complete, headers: { "Content-Type" => "text/event-stream" } })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 32_000)

      expect(result.tool_uses).to eq([{ id: "toolu_x", name: "api_write", input: { "endpoint" => "update_product" } }])
      expect(result.output_tokens).to eq(12_900)
    end

    it "estimates a discarded attempt's size from its half-written tool call when the provider reports no usage" do
      # The reason the attempt is discarded is usually that its tool-call JSON doesn't parse, so
      # there are no assembled arguments to measure — the half-written JSON string is itself what
      # the model generated, and charging zero for it would leave the largest turns free.
      allow(client).to receive(:sleep)
      half_written = %({"endpoint":"update_user_custom_html","params":{"custom_html":") + ("x" * 4_000)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: half_written } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 200,
                   body: { "content" => [{ "type" => "text", "text" => "done" }], "stop_reason" => "end_turn", "usage" => { "output_tokens" => 10 } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], max_tokens: 32_000)

      # Three discarded attempts, each estimated from the half-written JSON's own length.
      expect(result.output_tokens).to eq(10 + (3 * (half_written.length / 4.0).ceil))
    end

    it "hands the fallback's regenerated text to the caller's block in one piece when the replay is the final answer" do
      # A replay that comes back with no tool call is the finished reply, and it is what the seller
      # is meant to read. Nothing was streamed before the fallback fired (the fallback either
      # discards that text or is skipped), so this is the only time the caller sees it — deliver it
      # through the same block the stream would have used.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{broken" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered_body = {
        "content" => [{ "type" => "text", "text" => "Your product is already priced at $10." }],
        "stop_reason" => "end_turn",
      }
      stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 200, body: buffered_body.to_json, headers: { "Content-Type" => "application/json" })

      chunks = []
      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text }

      expect(chunks).to eq(["Your product is already priced at $10."])
      expect(result.text).to eq("Your product is already priced at $10.")
    end

    it "withholds the fallback's text from the caller's block when the buffered replay is a tool-use turn" do
      # A tool-use turn's text is preamble, not the answer: the caller clears it before rendering the
      # real reply. Yielding it here would flash the regenerated preamble onto the seller's screen
      # for an instant, between the discard that preceded the replay and the caller's own reset. The
      # text is still returned so the caller can record it as part of the turn.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{broken" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered_body = {
        "content" => [
          { "type" => "text", "text" => "Updating that now." },
          { "type" => "tool_use", "id" => "toolu_y", "name" => "api_write", "input" => { "endpoint" => "update_product" } },
        ],
        "stop_reason" => "tool_use",
      }
      stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 200, body: buffered_body.to_json, headers: { "Content-Type" => "application/json" })

      chunks = []
      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text }

      expect(chunks).to be_empty
      expect(result.text).to eq("Updating that now.")
      expect(result.tool_uses.first[:name]).to eq("api_write")
    end

    it "withholds the fallback's text from the caller's block when the buffered replay is itself truncated" do
      # A "max_tokens" turn is unusable, and the caller (StoreAgentService) handles that by telling
      # the UI to discard what it showed and streaming an honest truncation notice instead. Yielding
      # the incomplete text here would put a partial answer on the seller's screen for a moment
      # before the caller throws it away, so the text is returned but not streamed.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{broken" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered_body = {
        "content" => [{ "type" => "text", "text" => "Here is the first half of a long answer that got cut" }],
        "stop_reason" => "max_tokens",
      }
      stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 200, body: buffered_body.to_json, headers: { "Content-Type" => "application/json" })

      chunks = []
      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text }

      expect(chunks).to be_empty
      expect(result.stop_reason).to eq("max_tokens")
      expect(result.text).to eq("Here is the first half of a long answer that got cut")
    end

    it "surfaces the original unreadable-tool-call error when the non-streamed fallback also fails" do
      # The fallback must not make the failure murkier: if the buffered replay errors too, the
      # seller-facing error is the same clear "unreadable tool call" message as before the fallback
      # existed.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_read" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{not json" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      streamed = stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 500, body: { error: { message: "server error" } }.to_json)

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /unreadable tool call/i)
      expect(streamed).to have_been_requested.times(3)
      expect(buffered).to have_been_requested.once
    end

    it "surfaces the original unreadable-tool-call error when the fallback's own response body is cut off" do
      # The gateway failure this fallback recovers from is truncation, so the buffered replay can
      # come back as a 200 with a half-written body. Parsing that raises a JSON error, which would
      # otherwise reach the seller as a raw parser message that reads like a bug in our code — the
      # clear upstream-flavored error has to win instead.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{still not json" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      streamed = stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(status: 200, body: '{"content":[{"type":"tool_use","id":"toolu_y","name":"api_wr',
                   headers: { "Content-Type" => "application/json" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /unreadable tool call/i)
      expect(streamed).to have_been_requested.times(3)
      expect(buffered).to have_been_requested.once
    end

    it "surfaces the original error when the fallback is valid JSON but has no usable output" do
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{still not json" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      streamed = stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(
          status: 200,
          body: { "content" => [], "stop_reason" => "end_turn" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /unreadable tool call/i)
      expect(streamed).to have_been_requested.times(3)
      expect(buffered).to have_been_requested.once
    end

    it "surfaces the original error when the fallback tool input is not an object" do
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{still not json" } }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      streamed = stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered = stub_request(:post, url)
        .with(body: hash_including("stream" => false))
        .to_return(
          status: 200,
          body: {
            "content" => [{ "type" => "tool_use", "id" => "toolu_y", "name" => "api_write", "input" => "cut off" }],
            "stop_reason" => "tool_use",
          }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /unreadable tool call/i)
      expect(streamed).to have_been_requested.times(3)
      expect(buffered).to have_been_requested.once
    end

    it "does not retry a corrupted tool call once text has streamed and the caller can't discard it" do
      # Tool-use turns often stream preamble text before the tool_use block. When the caller has no
      # way to erase what the seller already saw, replaying the turn — streamed OR buffered — would
      # duplicate the reply on screen, so the corruption surfaces immediately instead: exactly one
      # request, no retry, no fallback.
      allow(client).to receive(:sleep)
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "Let me update that…" } }],
        ["content_block_start", { index: 1, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 1, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
        ["content_block_stop", { index: 1 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_t| } }
        .to raise_error(described_class::Error, /unreadable tool call/i)
      expect(a_request(:post, url)).to have_been_made.times(1)
      expect(a_request(:post, url).with(body: hash_including("stream" => false))).not_to have_been_made
      expect(client).not_to have_received(:sleep)
    end

    it "discards the streamed preamble and falls back when the caller can erase what was shown" do
      # The production shape of this failure: the model streams a sentence of preamble, then the
      # tool call's JSON arrives corrupted. Because the caller (the store agent) can clear the
      # preamble from the UI, the buffered replay is safe — it regenerates the turn onto an empty
      # transcript rather than appending a second copy underneath the first.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "Let me update that…" } }],
        ["content_block_start", { index: 1, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 1, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
        ["content_block_stop", { index: 1 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      streamed = stub_request(:post, url).with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      buffered = stub_request(:post, url).with(body: hash_including("stream" => false)).to_return(
        status: 200,
        body: {
          content: [{ type: "tool_use", id: "toolu_x", name: "api_write", input: { "endpoint" => "update_product" } }],
          stop_reason: "tool_use",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

      discarded = 0
      chunks = []
      result = client.stream_messages(
        system: "s",
        messages: [{ role: "user", content: "x" }],
        on_discard_streamed_text: -> { discarded += 1 },
      ) { |t| chunks << t }

      expect(discarded).to eq(1)
      expect(result.tool_uses.first[:input]).to eq("endpoint" => "update_product")
      # Only ONE streamed attempt: the existing retry veto still applies while the preamble is on
      # screen, so the streamed request is not replayed. The buffered replay is the recovery, and
      # it runs only after the preamble has been discarded.
      expect(streamed).to have_been_requested.once
      expect(buffered).to have_been_requested.once
      # The preamble was yielded, then discarded — the caller is responsible for clearing it, and
      # the buffered turn here carries no text of its own to replace it with.
      expect(chunks).to eq(["Let me update that…"])
    end

    it "surfaces the original error when the buffered replay fails after discarding streamed text" do
      # The discard already happened, so the seller's screen is empty. A failed replay must still
      # end in the clear unreadable-tool-call error rather than a raw upstream error.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "Let me update that…" } }],
        ["content_block_start", { index: 1, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 1, delta: { type: "input_json_delta", partial_json: '{"endpoint":"cut off' } }],
        ["content_block_stop", { index: 1 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url).with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      stub_request(:post, url).with(body: hash_including("stream" => false)).to_return(status: 500, body: "boom")

      discarded = 0
      expect do
        client.stream_messages(
          system: "s",
          messages: [{ role: "user", content: "x" }],
          on_discard_streamed_text: -> { discarded += 1 },
        ) { |_t| }
      end.to raise_error(described_class::Error, /unreadable tool call/i)
      expect(discarded).to eq(1)
    end

    it "retries when the stream drops mid-tool-call, leaving cut-off JSON and no stop_reason" do
      # A complete Anthropic stream always sends a stop_reason before ending. When the connection
      # drops mid-tool-call, the accumulated JSON is cut off at the disconnect and no stop_reason
      # ever arrives — that's a network failure, so the client should retry the request (nothing
      # reached the caller yet) instead of failing the turn as an unreadable tool call.
      allow(client).to receive(:sleep)
      dropped = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"description":"cut off here' } }],
      )
      complete = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product"}' } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .to_return({ status: 200, body: dropped, headers: { "Content-Type" => "text/event-stream" } },
                   { status: 200, body: complete, headers: { "Content-Type" => "text/event-stream" } })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "update my description" }])

      expect(result.tool_uses).to eq([{ id: "toolu_x", name: "api_write", input: { "endpoint" => "update_product" } }])
      expect(client).to have_received(:sleep).once
    end

    it "drops a tool call whose JSON was cut off by max_tokens instead of raising" do
      # When the stream stops with stop_reason "max_tokens", a half-written tool call's JSON is
      # expected (the token cap cut it off mid-arguments), not a model bug. Returning a Result with
      # the broken block dropped and stop_reason intact lets the caller handle the truncation
      # honestly instead of blowing up with "unreadable tool call".
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"description":"<p>very long' } }],
        ["message_delta", { delta: { stop_reason: "max_tokens" } }],
      )
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "update my description" }])

      expect(result.tool_uses).to eq([])
      expect(result.stop_reason).to eq("max_tokens")
      # Truncation is the caller's to handle (ask for a smaller change); the non-streamed fallback
      # is only for transport corruption and must not fire here.
      expect(a_request(:post, url).with(body: hash_including("stream" => false))).not_to have_been_made
    end

    it "raises Error on a stream-level error event" do
      stream = sse(["error", { error: { message: "overloaded" } }])
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /overloaded/i)
    end
  end
end
