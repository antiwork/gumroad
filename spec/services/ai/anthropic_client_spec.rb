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

    it "surfaces the unreadable-tool-call error once retries are exhausted on a completed turn" do
      # If every attempt produces unparseable tool arguments, it's not transient after all — the
      # caller still gets the honest "unreadable tool call" failure rather than a lossy {} dispatch.
      allow(client).to receive(:sleep)
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_read" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "{not json" } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::TransientError, /unreadable tool call/i)
      expect(a_request(:post, url)).to have_been_made.times(3)
    end

    it "does not retry a corrupted tool call once text has already streamed to the caller" do
      # Tool-use turns often stream preamble text before the tool_use block. Once any delta has
      # reached the caller, a retry would replay the reply from the start on the seller's screen,
      # so the corruption surfaces immediately instead — exactly one request, no retry.
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
      expect(client).not_to have_received(:sleep)
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
    end

    it "raises Error on a stream-level error event" do
      stream = sse(["error", { error: { message: "overloaded" } }])
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /overloaded/i)
    end
  end
end
