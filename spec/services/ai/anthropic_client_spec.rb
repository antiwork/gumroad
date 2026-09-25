# frozen_string_literal: true

require "spec_helper"

describe Ai::AnthropicClient do
  subject(:client) { described_class.new(timeout: 5) }

  let(:url) { "https://openrouter.ai/api/v1/messages" }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    # Pin routing so these specs do not depend on the host machine's environment.
    allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
    allow(GlobalConfig).to receive(:get).with("OPENROUTER_FALLBACK_MODEL").and_return(nil)
    allow(GlobalConfig).to receive(:get).with("STORE_AGENT_OPENROUTER_API_KEY").and_return(nil)
    allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return(nil)
  end

  def sse_stream(text)
    "event: content_block_start\ndata: #{{ index: 0, content_block: { type: "text" } }.to_json}\n\n" \
      "event: content_block_delta\ndata: #{{ index: 0, delta: { type: "text_delta", text: } }.to_json}\n\n" \
      "event: message_delta\ndata: #{{ delta: { stop_reason: "end_turn" } }.to_json}\n\n"
  end

  describe "#messages" do
    it "sends the system prompt, messages, and tools, and returns the assistant text" do
      body = { "content" => [{ "type" => "text", "text" => "You have 3 products." }], "stop_reason" => "end_turn" }
      stub = stub_request(:post, url)
        .with(
          headers: { "x-api-key" => "sk-or-test", "anthropic-version" => "2023-06-01" },
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

    it "includes thinking in the request body when given and omits it otherwise" do
      captured = nil
      stub_request(:post, url)
        .with { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }], thinking: { type: "disabled" })
      expect(captured["thinking"]).to eq("type" => "disabled")

      captured = nil
      client.messages(system: "s", messages: [{ role: "user", content: "x" }])
      expect(captured).not_to have_key("thinking")
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

    it "does not retry a tool-call token cutoff, and does not treat it as a transient error" do
      body = { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }.to_json
      stub = stub_request(:post, url).to_return(status: 400, body: body)

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::ToolCallTokenCutoffError, /Tool calls cutoff by max_tokens/)
      expect(stub).to have_been_requested.once
      expect(described_class::ToolCallTokenCutoffError).not_to be < described_class::TransientError
    end

    it "returns a max_tokens result for a tool-call token cutoff only when the caller opts in" do
      body = { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }.to_json
      stub = stub_request(:post, url).to_return(status: 400, body: body)

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }], recover_token_cutoff: true)

      expect(result).to have_attributes(text: "", tool_uses: [], stop_reason: "max_tokens")
      expect(stub).to have_been_requested.once
    end

    it "still raises a different max_tokens 400 when the caller opts in" do
      stub_request(:post, url).to_return(status: 400, body: { error: { message: "max_tokens must be positive" } }.to_json)

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }], recover_token_cutoff: true) }
        .to raise_error(described_class::Error, /max_tokens must be positive/)
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

    it "spends the deadline once across reads and lifts it on the first delta" do
      armed = []
      allow(HTTP::Client).to receive(:new).and_wrap_original do |original, options|
        opts = options.is_a?(HTTP::Options) ? options : HTTP::Options.new(options)
        armed << opts if opts.timeout_options.key?(:first_byte_timeout)
        original.call(opts)
      end

      stub_request(:post, url).to_return(status: 200, body: sse_stream("hi"), headers: { "Content-Type" => "text/event-stream" })
      described_class.new(timeout: 45).stream_messages(system: "s", messages: [{ role: "user", content: "x" }], ttft_deadline: 9) { |_| }

      expect(armed).not_to be_empty
      expect(armed.map(&:timeout_class)).to all(be < HTTP::Timeout::PerOperation)
      options = armed.last.timeout_options
      expect(options).to include(first_byte_timeout: 9, read_timeout: 45)
      # The stream's own first delta is what lifts the deadline for the rest of the stream.
      expect(options[:first_byte_marker]).to be_arrived

      waits = []
      fresh_marker = options[:first_byte_marker].class.new
      timeout = armed.last.timeout_class.new(options.merge(first_byte_marker: fresh_marker))
      timeout.instance_variable_set(:@socket, blocking_socket(waits))

      expect { timeout.readpartial(16) }.to raise_error(described_class::TtftDeadlineError)
      expect(waits.first).to be <= 9
      expect(waits.first).to be > 8

      # A second read before any delta gets what is left of the budget, not a fresh interval.
      sleep 0.01
      expect { timeout.readpartial(16) }.to raise_error(described_class::TtftDeadlineError)
      expect(waits.first - waits.last).to be > 0.005

      # Past the first delta a read timeout is silence, not the deadline — a different error class.
      fresh_marker.arrived!
      expect { timeout.readpartial(16) }.to raise_error(an_instance_of(HTTP::TimeoutError))
      expect(waits.last).to eq(45)
    end

    it "leaves the timeouts as they are today when no deadline is given" do
      allow(HTTP).to receive(:timeout).and_call_original
      armed = []
      allow(HTTP::Client).to receive(:new).and_wrap_original do |original, options|
        opts = options.is_a?(HTTP::Options) ? options : HTTP::Options.new(options)
        armed << opts if opts.timeout_options.key?(:first_byte_timeout)
        original.call(opts)
      end

      stub_request(:post, url).to_return(status: 200, body: sse_stream("hi"), headers: { "Content-Type" => "text/event-stream" })
      described_class.new(timeout: 45).stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| }

      expect(HTTP).to have_received(:timeout).with(
        connect: described_class::CONNECT_TIMEOUT_IN_SECONDS,
        write: described_class::WRITE_TIMEOUT_IN_SECONDS,
        read: 45,
      )
      expect(armed).to be_empty
    end

    # A socket that never becomes readable, so #readpartial runs its timeout path and the error
    # names the read timeout it waited with.
    def blocking_socket(waits)
      io = Object.new
      io.define_singleton_method(:wait_readable) { |seconds| waits << seconds; false }

      socket = Object.new
      socket.define_singleton_method(:to_io) { io }
      socket.define_singleton_method(:read_nonblock) { |_size, _buffer = nil, **_options| :wait_readable }
      socket
    end
  end

  describe "first-byte deadline failover" do
    let(:vercel_url) { "https://ai-gateway.vercel.sh/v1/messages" }
    let(:vercel_client) do
      described_class.new(timeout: 120, model: "deepseek/deepseek-v4.1-flash", fallback_model: "anthropic/claude-opus-5")
    end

    before do
      allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return("gw-test")
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return(nil)
    end

    it "re-issues on the fallback model when the deadline expires before any output" do
      calls = 0
      allow(vercel_client).to receive(:http).and_wrap_original do |original, **kwargs|
        calls += 1
        raise described_class::TtftDeadlineError, "Anthropic produced no output within 15s" if calls == 1

        original.call(**kwargs)
      end
      opus = stub_request(:post, vercel_url)
        .with(body: hash_including("model" => "anthropic/claude-opus-5"))
        .to_return(status: 200, body: sse_stream("hi"), headers: { "Content-Type" => "text/event-stream" })
      allow(vercel_client).to receive(:sleep)

      chunks = []
      result = vercel_client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], ttft_deadline: 15) { |text| chunks << text }

      expect(chunks).to eq(["hi"])
      expect(result.text).to eq("hi")
      expect(opus).to have_been_requested.once
      # The stalled attempt is what telemetry records, and no same-model retry spent the deadline again.
      expect(vercel_client.call_metrics.first[:error]).to eq(described_class::TtftDeadlineError.name)
      expect(vercel_client).not_to have_received(:sleep)
    end

    it "keeps the ordinary retries when the timeout is not the deadline" do
      # WebMock's to_timeout raises the plain HTTP::TimeoutError — a connection-level failure, not
      # the deadline-bounded read — so the same model keeps its retries.
      deepseek = stub_request(:post, vercel_url)
        .with(body: hash_including("model" => "deepseek/deepseek-v4.1-flash"))
        .to_timeout
        .then
        .to_return(status: 200, body: sse_stream("hi"), headers: { "Content-Type" => "text/event-stream" })
      allow(vercel_client).to receive(:sleep)

      chunks = []
      vercel_client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], ttft_deadline: 15) { |text| chunks << text }

      expect(deepseek).to have_been_requested.twice
      expect(chunks).to eq(["hi"])
      expect(vercel_client).to have_received(:sleep).once
    end

    it "leaves the fallback replay on the ordinary timeouts" do
      allow(HTTP).to receive(:timeout).and_call_original
      calls = 0
      allow(vercel_client).to receive(:http).and_wrap_original do |original, **kwargs|
        calls += 1
        raise described_class::TtftDeadlineError, "Anthropic produced no output within 15s" if calls == 1

        original.call(**kwargs)
      end
      allow(vercel_client).to receive(:sleep)
      stub_request(:post, vercel_url)
        .to_return(status: 200, body: sse_stream("hi"), headers: { "Content-Type" => "text/event-stream" })

      vercel_client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], ttft_deadline: 15) { |_| }

      expect(HTTP).to have_received(:timeout).with(
        connect: described_class::CONNECT_TIMEOUT_IN_SECONDS,
        write: described_class::WRITE_TIMEOUT_IN_SECONDS,
        read: 120,
      )
    end

    it "keeps re-issuing the same model when no deadline was given" do
      allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
      allow(client).to receive(:sleep)
      stub_request(:post, url).to_timeout

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| } }
        .to raise_error(described_class::TransientError, /network error/i)
      expect(client).to have_received(:sleep).twice
    end
  end

  describe "API key resolution" do
    it "prefers the store agent's own OpenRouter key on the default route" do
      allow(GlobalConfig).to receive(:get).with("STORE_AGENT_OPENROUTER_API_KEY").and_return("sk-or-store-agent")

      stub = stub_request(:post, url)
        .with(headers: { "x-api-key" => "sk-or-store-agent" })
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
    end

    it "raises instead of calling Anthropic directly when no OpenRouter key is configured" do
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("")
      allow(GlobalConfig).to receive(:get).with("WALKS_ANTHROPIC_API_KEY").and_return("sk-ant-walks")
      openrouter = stub_request(:post, url)
      anthropic = stub_request(:post, "https://api.anthropic.com/v1/messages")

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /not configured/i)
      expect(openrouter).not_to have_been_requested
      expect(anthropic).not_to have_been_requested
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

    it "prefers a per-instance fallback_model over the config override" do
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_FALLBACK_MODEL").and_return("openai/gpt-4o")
      captured = nil
      stub_request(:post, openrouter_url)
        .with { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      described_class.new(fallback_model: "anthropic/claude-opus-4.7")
        .messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(captured["fallbacks"]).to eq([{ "model" => "anthropic/claude-opus-4.7" }])
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

    describe "served-model logging" do
      before { allow(Rails.logger).to receive(:warn) }

      it "warns when a buffered response was served by a different model than requested" do
        body = { "model" => "openai/gpt-5", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }
        stub_request(:post, openrouter_url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

        client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(Rails.logger).to have_received(:warn).with(/served by fallback model openai\/gpt-5 via openrouter \(requested #{described_class::DEFAULT_MODEL}\)/o)
      end

      it "warns when a stream's message_start names a different model than requested" do
        stream = "event: message_start\ndata: #{{ message: { model: "openai/gpt-5" } }.to_json}\n\n" \
                 "event: content_block_start\ndata: #{{ index: 0, content_block: { type: "text" } }.to_json}\n\n" \
                 "event: content_block_delta\ndata: #{{ index: 0, delta: { type: "text_delta", text: "hi" } }.to_json}\n\n" \
                 "event: message_delta\ndata: #{{ delta: { stop_reason: "end_turn" } }.to_json}\n\n"
        stub_request(:post, openrouter_url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

        client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| }

        expect(Rails.logger).to have_received(:warn).with(/served by fallback model openai\/gpt-5 via openrouter/)
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

  describe "Vercel AI Gateway routing" do
    let(:vercel_url) { "https://ai-gateway.vercel.sh/v1/messages" }
    let(:openrouter_url) { "https://openrouter.ai/api/v1/messages" }
    subject(:client) do
      described_class.new(
        timeout: 5,
        model: "deepseek/deepseek-v4.1-flash",
        fallback_model: "anthropic/claude-opus-5",
      )
    end

    before do
      allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return("sk-vercel-test")
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return(nil)
    end

    it "routes to Vercel with the store agent's gateway key, no OpenRouter fallbacks, and Vercel model failover" do
      captured = nil
      stub = stub_request(:post, vercel_url)
        .with(headers: { "x-api-key" => "sk-vercel-test", "anthropic-version" => "2023-06-01" }) { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "model" => "deepseek/deepseek-v4.1-flash", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
      expect(result.text).to eq("ok")
      expect(client.gateway_name).to eq("vercel")
      expect(captured["model"]).to eq("deepseek/deepseek-v4.1-flash")
      expect(captured).not_to have_key("fallbacks")
      expect(captured["providerOptions"]).to eq("gateway" => { "models" => ["anthropic/claude-opus-5"] })
      expect(client.served_models).to eq(["deepseek/deepseek-v4.1-flash"])
    end

    it "falls back to OpenRouter when the store agent has no gateway key" do
      allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
      captured = nil
      stub = stub_request(:post, openrouter_url)
        .with(headers: { "x-api-key" => "sk-or-test" }) { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
      expect(result.text).to eq("ok")
      expect(client.gateway_name).to eq("openrouter")
      expect(captured["fallbacks"]).to eq([{ "model" => "anthropic/claude-opus-5" }])
      expect(captured).not_to have_key("providerOptions")
    end

    it "prefers the store agent's own OpenRouter key over the shared one" do
      allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
      allow(GlobalConfig).to receive(:get).with("STORE_AGENT_OPENROUTER_API_KEY").and_return("sk-or-store-agent")
      stub = stub_request(:post, openrouter_url)
        .with(headers: { "x-api-key" => "sk-or-store-agent" })
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
    end

    context "when OpenRouter is configured" do
      let(:credit_error) { { status: 402, body: { error: { message: "A positive credit balance is required" } }.to_json } }
      let(:reply) { { "model" => "anthropic/claude-opus-5", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" } }

      before do
        allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
      end

      it "uses OpenRouter credentials and format for the fallback, then restores Vercel for the next call" do
        allow(Rails.logger).to receive(:warn)
        primary = stub_request(:post, vercel_url)
          .with(headers: { "x-api-key" => "sk-vercel-test" }, body: hash_including("model" => "deepseek/deepseek-v4.1-flash"))
          .to_return(credit_error, { status: 200, body: reply.merge("model" => "deepseek/deepseek-v4.1-flash").to_json, headers: { "Content-Type" => "application/json" } })
        captured = nil
        fallback = stub_request(:post, openrouter_url)
          .with(headers: { "x-api-key" => "sk-or-test" }) { |request| captured = JSON.parse(request.body); true }
          .to_return(status: 200, body: reply.to_json, headers: { "Content-Type" => "application/json" })

        result = client.messages(system: "s", messages: [{ role: "user", content: "x" }], thinking: { type: "disabled" })

        expect(result.text).to eq("ok")
        expect(captured["model"]).to eq("anthropic/claude-opus-5")
        expect(captured.keys).not_to include("providerOptions", "fallbacks", "thinking")
        expect(client.call_metrics.map { |call| call.slice(:gateway, :status) }).to eq(
          [{ gateway: "vercel", status: 402 }, { gateway: "openrouter", status: 200 }]
        )
        expect(Rails.logger).to have_received(:warn).with(a_string_matching(/replaying fallback.*gateway=openrouter/))

        expect(client.messages(system: "s", messages: [{ role: "user", content: "y" }]).text).to eq("ok")
        expect(primary).to have_been_requested.twice
        expect(fallback).to have_been_requested.once
        expect(client.gateway_name).to eq("vercel")
      end

      it "sends the store agent's Grok route to Vercel on its own key and replays the Opus fallback on its own OpenRouter key" do
        allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return("sk-vercel-store-agent")
        allow(GlobalConfig).to receive(:get).with("STORE_AGENT_OPENROUTER_API_KEY").and_return("sk-or-store-agent")
        grok_client = described_class.new(
          timeout: 5,
          model: Ai::StoreAgentService::GROK_MODEL,
          fallback_model: Ai::StoreAgentService::GROK_FALLBACK_MODEL,
        )
        primary = stub_request(:post, vercel_url)
          .with(
            headers: { "x-api-key" => "sk-vercel-store-agent" },
            body: hash_including("model" => "x-ai/grok-4.5", "providerOptions" => { "gateway" => { "models" => ["anthropic/claude-opus-5"] } }),
          )
          .to_return(credit_error)
        fallback = stub_request(:post, openrouter_url)
          .with(headers: { "x-api-key" => "sk-or-store-agent" }, body: hash_including("model" => "anthropic/claude-opus-5"))
          .to_return(status: 200, body: reply.to_json, headers: { "Content-Type" => "application/json" })

        result = grok_client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(result.text).to eq("ok")
        expect(primary).to have_been_requested.once
        expect(fallback).to have_been_requested.once
        expect(grok_client.call_metrics.map { |call| call.slice(:gateway, :status) }).to eq(
          [{ gateway: "vercel", status: 402 }, { gateway: "openrouter", status: 200 }]
        )
      end

      it "streams the OpenRouter fallback when Vercel rejects a request for insufficient credits" do
        primary = stub_request(:post, vercel_url).to_return(credit_error)
        fallback = stub_request(:post, openrouter_url)
          .with(headers: { "x-api-key" => "sk-or-test" }, body: hash_including("model" => "anthropic/claude-opus-5", "stream" => true))
          .to_return(status: 200, body: sse_stream("ok"), headers: { "Content-Type" => "text/event-stream" })
        chunks = []

        result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text }

        expect(result.text).to eq("ok")
        expect(result.stop_reason).to eq("end_turn")
        expect(chunks).to eq(["ok"])
        expect(primary).to have_been_requested.once
        expect(fallback).to have_been_requested.once
        expect(client.call_metrics.map { |call| call[:gateway] }).to eq(%w[vercel openrouter])
      end

      it "keeps unreadable stream recovery on OpenRouter before restoring the primary gateway" do
        allow(client).to receive(:sleep)
        primary = stub_request(:post, vercel_url).to_return(credit_error)
        corrupted = [
          ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_1", name: "api_read" } }],
          ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: "not-json" } }],
          ["message_delta", { delta: { stop_reason: "tool_use" } }],
        ].map { |event, data| "event: #{event}\ndata: #{data.to_json}\n\n" }.join
        streamed = stub_request(:post, openrouter_url)
          .with(headers: { "x-api-key" => "sk-or-test" }, body: hash_including("model" => "anthropic/claude-opus-5", "stream" => true))
          .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
        buffered = stub_request(:post, openrouter_url)
          .with(headers: { "x-api-key" => "sk-or-test" }, body: hash_including("model" => "anthropic/claude-opus-5", "stream" => false))
          .to_return(status: 200, body: reply.to_json, headers: { "Content-Type" => "application/json" })
        chunks = []

        result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text }

        expect(result.text).to eq("ok")
        expect(chunks).to eq(["ok"])
        expect(primary).to have_been_requested.once
        expect(streamed).to have_been_requested.times(described_class::MAX_ATTEMPTS)
        expect(buffered).to have_been_requested.once
        expect(client.call_metrics.map { |call| call[:gateway] }).to eq(%w[vercel openrouter openrouter])
        expect(client.gateway_name).to eq("vercel")
      end

      it "raises an OpenRouter failure once and restores the primary gateway" do
        primary = stub_request(:post, vercel_url).to_return(credit_error)
        fallback = stub_request(:post, openrouter_url)
          .to_return(status: 401, body: { error: { message: "Invalid OpenRouter key" } }.to_json)

        expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
          .to raise_error(described_class::Error, /Invalid OpenRouter key/)

        expect(primary).to have_been_requested.once
        expect(fallback).to have_been_requested.once
        expect(client.gateway_name).to eq("vercel")
      end

      it "does not replay on OpenRouter after streaming text to the caller" do
        stream = "event: content_block_start\ndata: #{{ index: 0, content_block: { type: "text" } }.to_json}\n\n" \
                 "event: content_block_delta\ndata: #{{ index: 0, delta: { type: "text_delta", text: "partial" } }.to_json}\n\n" \
                 "event: error\ndata: #{{ error: { type: "api_error", message: "Interrupted" } }.to_json}\n\n"
        primary = stub_request(:post, vercel_url)
          .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })
        chunks = []

        expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text } }
          .to raise_error(described_class::TransientError, /Interrupted/)

        expect(chunks).to eq(["partial"])
        expect(primary).to have_been_requested.once
        expect(WebMock).not_to have_requested(:post, openrouter_url)
      end
    end

    it "does not replay a tool-call token cutoff on the fallback model" do
      cutoff = { status: 400, body: { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }.to_json }
      primary = stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "deepseek/deepseek-v4.1-flash" }
        .to_return(cutoff)
      fallback = stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "anthropic/claude-opus-5" }
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }], recover_token_cutoff: true)

      expect(result).to have_attributes(text: "", tool_uses: [], stop_reason: "max_tokens")
      expect(primary).to have_been_requested.once
      expect(fallback).not_to have_been_requested
    end

    it "returns max_tokens for a no-text streamed cutoff without replaying the fallback model" do
      stream = [
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"description":"<p>cut' } }],
        ["error", { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }],
      ].map { |event, data| "event: #{event}\ndata: #{data.to_json}\n\n" }.join
      primary = stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "deepseek/deepseek-v4.1-flash" }
        .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })
      fallback = stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "anthropic/claude-opus-5" }
        .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], recover_token_cutoff: true)

      expect(result).to have_attributes(text: "", tool_uses: [], stop_reason: "max_tokens")
      expect(primary).to have_been_requested.once
      expect(fallback).not_to have_been_requested
    end

    it "replays the Opus fallback on Vercel when OpenRouter is not configured" do
      stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "deepseek/deepseek-v4.1-flash" }
        .to_return(status: 400, body: { error: { message: "unavailable" } }.to_json)
      fallback = stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "anthropic/claude-opus-5" }
        .to_return(status: 200, body: { "model" => "anthropic/claude-opus-5", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(fallback).to have_been_requested
      expect(result.text).to eq("ok")
      expect(client.served_models).to eq(["anthropic/claude-opus-5"])
    end

    it "drops a caller's thinking override on the fallback replay" do
      # The override is scoped to the requested model. The replay goes to a different one, so sending
      # it there would change a request the caller has no opinion about.
      captured = []
      stub_request(:post, vercel_url).to_return do |request|
        body = JSON.parse(request.body)
        captured << body
        if body["model"] == "deepseek/deepseek-v4.1-flash"
          { status: 400, body: { error: { message: "unavailable" } }.to_json }
        else
          { status: 200, body: { "model" => "anthropic/claude-opus-5", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" } }
        end
      end

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }], thinking: { type: "disabled" })

      expect(result.text).to eq("ok")
      expect(captured.first["thinking"]).to eq("type" => "disabled")
      expect(captured.last["model"]).to eq("anthropic/claude-opus-5")
      expect(captured.last).not_to have_key("thinking")
    end

    it "warns with the primary error before replaying the fallback model" do
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:info)
      stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "deepseek/deepseek-v4.1-flash" }
        .to_return(status: 400, body: { error: { message: "unavailable" } }.to_json)
      stub_request(:post, vercel_url)
        .with { |request| JSON.parse(request.body)["model"] == "anthropic/claude-opus-5" }
        .to_return(status: 200, body: { "model" => "anthropic/claude-opus-5", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(Rails.logger).to have_received(:warn).with(a_string_matching(
        /Anthropic Vercel primary failed \(Ai::AnthropicClient::Error:.*unavailable\).*requested=deepseek\/deepseek-v4.1-flash gateway=vercel/
      ))
    end

    it "restores the primary model after a fallback replay so the next request still sends gateway models" do
      captured = []
      stub_request(:post, vercel_url).to_return do |request|
        body = JSON.parse(request.body)
        captured << body
        if body["model"] == "deepseek/deepseek-v4.1-flash" && captured.one?
          { status: 400, body: { error: { message: "unavailable" } }.to_json }
        elsif body["model"] == "anthropic/claude-opus-5"
          { status: 200, body: { "model" => "anthropic/claude-opus-5", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" } }
        else
          { status: 200, body: { "model" => "deepseek/deepseek-v4.1-flash", "content" => [{ "type" => "text", "text" => "ok2" }], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" } }
        end
      end

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])
      client.messages(system: "s", messages: [{ role: "user", content: "y" }])

      expect(captured.map { |body| body["model"] }).to eq(
        ["deepseek/deepseek-v4.1-flash", "anthropic/claude-opus-5", "deepseek/deepseek-v4.1-flash"]
      )
      expect(captured.last["providerOptions"]).to eq("gateway" => { "models" => ["anthropic/claude-opus-5"] })
    end

    it "logs the gateway name with the served model" do
      allow(Rails.logger).to receive(:info)
      stub_request(:post, vercel_url)
        .to_return(status: 200, body: { "model" => "deepseek/deepseek-v4.1-flash", "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(Rails.logger).to have_received(:info).with(/served by deepseek\/deepseek-v4.1-flash via vercel/)
    end

    it "routes a default Opus client through Vercel ahead of a configured OpenRouter key" do
      allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
      default_client = described_class.new(timeout: 5)
      captured = nil
      stub = stub_request(:post, vercel_url)
        .with { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      default_client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(stub).to have_been_requested
      expect(default_client.gateway_name).to eq("vercel")
      expect(captured["model"]).to eq(described_class::DEFAULT_MODEL)
      expect(captured).not_to have_key("fallbacks")
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

    it "includes thinking in the request body when given and omits it otherwise" do
      captured = nil
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "hi" } }],
        ["message_delta", { delta: { stop_reason: "end_turn" } }],
      )
      stub_request(:post, url)
        .with { |request| captured = JSON.parse(request.body); true }
        .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], thinking: { type: "disabled" }) { |_| }
      expect(captured["thinking"]).to eq("type" => "disabled")

      captured = nil
      client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| }
      expect(captured).not_to have_key("thinking")
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

    it "carries thinking into the buffered replay of an unreadable tool call" do
      # The replay is the same seller turn on the same requested model, so an override the caller
      # set for that model has to survive it. Without this the flagged DeepSeek turn turns hidden
      # reasoning back on for exactly the replayed request.
      allow(client).to receive(:sleep)
      corrupted = sse(
        ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "tool_use" } }],
      )
      stub_request(:post, url)
        .with(body: hash_including("stream" => true))
        .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
      replayed = nil
      stub_request(:post, url)
        .with { |request| replayed = JSON.parse(request.body); replayed["stream"] == false }
        .to_return(status: 200, body: {
          "content" => [{ "type" => "tool_use", "id" => "toolu_y", "name" => "api_write", "input" => { "endpoint" => "update_product" } }],
          "stop_reason" => "tool_use",
        }.to_json, headers: { "Content-Type" => "application/json" })

      client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], thinking: { type: "disabled" })

      expect(replayed["thinking"]).to eq("type" => "disabled")
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

    it "raises ToolCallTokenCutoffError when a stream api_error reports a tool-call token cutoff" do
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "Updating that now. " } }],
        ["error", { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }],
      )
      stub = stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })
      chunks = []

      expect { client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |text| chunks << text } }
        .to raise_error(described_class::ToolCallTokenCutoffError, /Tool calls cutoff by max_tokens/)

      expect(chunks).to eq(["Updating that now. "])
      expect(stub).to have_been_requested.once
      expect(a_request(:post, url).with(body: hash_including("stream" => false))).not_to have_been_made
    end

    it "returns max_tokens for a streamed tool-call cutoff when the caller opts in, without replaying" do
      stream = sse(
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "Updating that now. " } }],
        ["content_block_start", { index: 1, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
        ["content_block_delta", { index: 1, delta: { type: "input_json_delta", partial_json: "{\"description\":\"<p>cut" } }],
        ["error", { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }],
      )
      stub = stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })
      chunks = []

      result = client.stream_messages(
        system: "s",
        messages: [{ role: "user", content: "x" }],
        recover_token_cutoff: true,
      ) { |text| chunks << text }

      expect(result).to have_attributes(text: "", tool_uses: [], stop_reason: "max_tokens")
      expect(chunks).to eq(["Updating that now. "])
      expect(stub).to have_been_requested.once
      expect(a_request(:post, url).with(body: hash_including("stream" => false))).not_to have_been_made
    end

    it "does not turn a different stream api_error into max_tokens when the caller opts in" do
      stream = sse(["error", { error: { type: "api_error", message: "Interrupted" } }])
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      expect do
        client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], recover_token_cutoff: true)
      end.to raise_error(described_class::TransientError, /Interrupted/)
    end
  end

  # Per-call latency/TTFT/tokens/provider, read by StoreAgentService after a turn. The clock is
  # stubbed because every measurement here is a delta between two reads of it.
  describe "call metrics" do
    def sse(*events)
      events.map { |event, data| "event: #{event}\ndata: #{data.to_json}\n\n" }.join
    end

    # One read at the call's start, one at its first byte/delta, one when it ends.
    def stub_call_clock(*offsets)
      allow(client).to receive(:monotonic_now).and_return(*offsets)
    end

    it "records latency, TTFT, tokens and the served model for a buffered call" do
      stub_call_clock(10.0, 10.4, 10.9)
      body = {
        "model" => "claude-opus-4-7",
        "content" => [{ "type" => "text", "text" => "ok" }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 120, "output_tokens" => 8, "cache_read_input_tokens" => 90 },
      }
      stub_request(:post, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(client.call_metrics).to eq(
        [
          {
            streamed: false,
            buffered_fallback: false,
            latency_ms: 900,
            ttft_ms: 400,
            retries: 0,
            input_tokens: 120,
            output_tokens: 8,
            cache_read_input_tokens: 90,
            cache_creation_input_tokens: nil,
            reasoning_tokens: nil,
            served_model: "claude-opus-4-7",
            served_provider: nil,
            gateway: "openrouter",
            status: 200,
            error: nil,
          },
        ],
      )
    end

    it "times TTFT from the first delta of a multi-delta stream, not the last" do
      stub_call_clock(0.0, 0.25, 1.5)
      stream = sse(
        ["message_start", { message: { model: "claude-opus-4-7" } }],
        ["content_block_start", { index: 0, content_block: { type: "text" } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "You have " } }],
        ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "3 products." } }],
        ["content_block_stop", { index: 0 }],
        ["message_delta", { delta: { stop_reason: "end_turn" } }],
      )
      stub_request(:post, url).to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| }

      expect(client.call_metrics.first).to include(ttft_ms: 250, latency_ms: 1500)
    end

    context "through OpenRouter" do
      let(:openrouter_url) { "https://openrouter.ai/api/v1/messages" }

      before do
        allow(GlobalConfig).to receive(:get).with("OPENROUTER_API_KEY").and_return("sk-or-test")
        allow(GlobalConfig).to receive(:get).with("OPENROUTER_FALLBACK_MODEL").and_return(nil)
      end

      it "times TTFT from the first content delta and merges usage split across message_start and message_delta" do
        stub_call_clock(0.0, 0.25, 1.5)
        stream = sse(
          ["message_start", { message: { model: "deepseek/deepseek-v4.1-flash", usage: { "input_tokens" => 900, "cache_read_input_tokens" => 640 } } }],
          ["content_block_start", { index: 0, content_block: { type: "text" } }],
          ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "hi" } }],
          ["message_delta", { delta: { stop_reason: "end_turn" }, usage: { "output_tokens" => 30, "reasoning_tokens" => 11 } }],
        )
        stub_request(:post, openrouter_url)
          .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream", "x-or-provider" => "DeepInfra" })

        client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| }

        expect(client.call_metrics).to eq(
          [
            {
              streamed: true,
              buffered_fallback: false,
              latency_ms: 1500,
              ttft_ms: 250,
              retries: 0,
              input_tokens: 900,
              output_tokens: 30,
              cache_read_input_tokens: 640,
              cache_creation_input_tokens: nil,
              reasoning_tokens: 11,
              served_model: "deepseek/deepseek-v4.1-flash",
              served_provider: "DeepInfra",
              gateway: "openrouter",
              status: 200,
              error: nil,
            },
          ],
        )
      end
    end

    context "through the Vercel gateway" do
      let(:vercel_url) { "https://ai-gateway.vercel.sh/v1/messages" }

      subject(:client) do
        described_class.new(
          timeout: 5,
          model: "deepseek/deepseek-v4.1-flash",
          fallback_model: "anthropic/claude-opus-5",
        )
      end

      before do
        allow(GlobalConfig).to receive(:get).with("STORE_AGENT_AI_GATEWAY_API_KEY").and_return("sk-vercel-test")
      end

      it "reads the served provider from the gateway's response header" do
        stub_call_clock(0.0, 0.6, 0.8)
        stub_request(:post, vercel_url).to_return(
          status: 200,
          body: { "model" => "deepseek/deepseek-v4.1-flash", "content" => [], "stop_reason" => "end_turn" }.to_json,
          headers: { "Content-Type" => "application/json", "x-vercel-ai-gateway-provider" => "deepinfra" },
        )

        client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(client.call_metrics.first)
          .to include(gateway: "vercel", served_provider: "deepinfra", served_model: "deepseek/deepseek-v4.1-flash")
      end

      it "reads the served provider from the streamed message_delta when no header is sent" do
        stub_call_clock(0.0, 0.3, 1.0)
        stream = sse(
          ["message_start", { message: { model: "deepseek/deepseek-v4.1-flash" } }],
          ["content_block_start", { index: 0, content_block: { type: "text" } }],
          ["content_block_delta", { index: 0, delta: { type: "text_delta", text: "hi" } }],
          ["message_delta", { delta: { stop_reason: "end_turn" },
                              provider_metadata: { gateway: { routing: { resolvedProvider: "alibaba" } } } }],
        )
        stub_request(:post, vercel_url)
          .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

        client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }]) { |_| }

        expect(client.call_metrics.first).to include(gateway: "vercel", served_provider: "alibaba")
      end

      it "reads the served provider from a buffered body's routing metadata" do
        stub_call_clock(0.0, 0.3, 0.6)
        body = {
          "model" => "deepseek/deepseek-v4.1-flash",
          "content" => [],
          "stop_reason" => "end_turn",
          "provider_metadata" => { "gateway" => { "routing" => { "resolvedProvider" => "baseten" } } },
        }
        stub_request(:post, vercel_url)
          .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

        client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(client.call_metrics.first).to include(gateway: "vercel", served_provider: "baseten")
      end

      it "prefers a response header over the body's routing metadata" do
        stub_call_clock(0.0, 0.3, 0.6)
        body = {
          "model" => "deepseek/deepseek-v4.1-flash",
          "content" => [],
          "stop_reason" => "end_turn",
          "provider_metadata" => { "gateway" => { "routing" => { "resolvedProvider" => "baseten" } } },
        }
        stub_request(:post, vercel_url).to_return(
          status: 200,
          body: body.to_json,
          headers: { "Content-Type" => "application/json", "x-vercel-ai-gateway-provider" => "deepinfra" },
        )

        client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(client.call_metrics.first).to include(served_provider: "deepinfra")
      end

      it "keeps TTFT and latency on the attempt that delivered when the first attempt is retried" do
        allow(client).to receive(:sleep)
        stub_call_clock(0.0, 0.1, 0.2, 1.0)
        body = { "model" => "deepseek/deepseek-v4.1-flash", "content" => [], "stop_reason" => "end_turn" }
        stub_request(:post, vercel_url)
          .to_return({ status: 529, body: { error: { type: "overloaded_error", message: "Overloaded" } }.to_json },
                     { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } })

        client.messages(system: "s", messages: [{ role: "user", content: "x" }])

        expect(client.call_metrics).to contain_exactly(
          hash_including(retries: 1, ttft_ms: 200, latency_ms: 1000, status: 200, error: nil),
        )
      end

      it "records the buffered replay as its own entry, after the streamed call it recovered" do
        allow(client).to receive(:sleep)
        stub_call_clock(0.0, 0.1, 0.2, 0.3, 0.4, 10.0, 10.5, 11.0)
        corrupted = sse(
          ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
          ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
          ["message_delta", { delta: { stop_reason: "tool_use" } }],
        )
        stub_request(:post, vercel_url).with(body: hash_including("stream" => true))
          .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
        stub_request(:post, vercel_url).with(body: hash_including("stream" => false)).to_return(
          status: 200,
          body: { "model" => "deepseek/deepseek-v4.1-flash", "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

        client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }])

        streamed, replay = client.call_metrics
        expect(streamed).to include(
          streamed: true,
          buffered_fallback: false,
          retries: 2,
          latency_ms: 400,
          status: 200,
          error: "Ai::AnthropicClient::UnreadableToolCallError",
        )
        expect(replay).to include(streamed: false, buffered_fallback: true, retries: 0, latency_ms: 1000, error: nil)
      end

      it "turns a cutoff on the buffered replay into truncation when the caller opts in" do
        allow(client).to receive(:sleep)
        stub_call_clock(0.0, 0.1, 0.2, 0.3, 0.4, 10.0, 10.5, 11.0)
        corrupted = sse(
          ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
          ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
          ["message_delta", { delta: { stop_reason: "tool_use" } }],
        )
        stub_request(:post, vercel_url).with(body: hash_including("stream" => true))
          .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
        # The replay regenerates the turn, so it is the longest attempt and can hit the same cap.
        stub_request(:post, vercel_url).with(body: hash_including("stream" => false)).to_return(
          status: 400,
          body: { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

        result = client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }], recover_token_cutoff: true)

        expect(result.stop_reason).to eq("max_tokens")
        expect(result.tool_uses).to eq([])
        expect(client.call_metrics.last).to include(
          streamed: false,
          buffered_fallback: true,
          error: "Ai::AnthropicClient::ToolCallTokenCutoffError",
        )
      end

      it "keeps the unreadable-tool-call error when the caller has not opted into cutoff recovery" do
        allow(client).to receive(:sleep)
        stub_call_clock(0.0, 0.1, 0.2, 0.3, 0.4, 10.0, 10.5, 11.0)
        corrupted = sse(
          ["content_block_start", { index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "api_write" } }],
          ["content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: '{"endpoint":"update_product","params":{"name":"cut off' } }],
          ["message_delta", { delta: { stop_reason: "tool_use" } }],
        )
        stub_request(:post, vercel_url).with(body: hash_including("stream" => true))
          .to_return(status: 200, body: corrupted, headers: { "Content-Type" => "text/event-stream" })
        stub_request(:post, vercel_url).with(body: hash_including("stream" => false)).to_return(
          status: 400,
          body: { error: { type: "api_error", message: "HttpError: HTTP 400: Tool calls cutoff by max_tokens." } }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

        expect do
          client.stream_messages(system: "s", messages: [{ role: "user", content: "x" }])
        end.to raise_error(described_class::UnreadableToolCallError)
      end
    end

    it "reports a missing token or provider field as nil, never 0" do
      stub_call_clock(0.0, 0.1, 0.2)
      body = {
        "content" => [{ "type" => "text", "text" => "ok" }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => "not a number", "output_tokens_details" => 5 },
      }
      stub_request(:post, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(client.call_metrics.first).to include(
        input_tokens: nil,
        output_tokens: nil,
        cache_read_input_tokens: nil,
        cache_creation_input_tokens: nil,
        reasoning_tokens: nil,
        served_model: nil,
        served_provider: nil,
      )
    end

    it "records a call that never succeeded, with its error class and status" do
      stub_call_clock(0.0, 0.3, 0.5)
      stub_request(:post, url).to_return(status: 400, body: { error: { message: "bad request" } }.to_json)

      expect { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }
        .to raise_error(described_class::Error, /bad request/)

      expect(client.call_metrics).to contain_exactly(
        hash_including(status: 400, error: "Ai::AnthropicClient::Error", latency_ms: 500, input_tokens: nil),
      )
    end

    it "never fails the call when a metric cannot be recorded" do
      allow(Rails.logger).to receive(:warn)
      # The latency read raises, as it would on a clock that returned something unusable.
      stub_call_clock(0.0, 0.1, "not a time")
      stub_request(:post, url).to_return(status: 200, body: { "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" })

      result = client.messages(system: "s", messages: [{ role: "user", content: "x" }])

      expect(result.stop_reason).to eq("end_turn")
      expect(client.call_metrics).to eq([])
      expect(Rails.logger).to have_received(:warn).with(/call metrics not recorded/)
    end

    it "attributes each entry's served model to its own response" do
      stub_call_clock(0.0, 0.1, 0.2, 5.0, 5.1, 5.2)
      stub_request(:post, url).to_return(
        { status: 200, body: { "model" => "claude-opus-4-7", "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { "model" => "openai/gpt-5", "content" => [], "stop_reason" => "end_turn" }.to_json, headers: { "Content-Type" => "application/json" } },
      )
      allow(Rails.logger).to receive(:warn)

      2.times { client.messages(system: "s", messages: [{ role: "user", content: "x" }]) }

      expect(client.call_metrics.map { |call| call[:served_model] }).to eq(["claude-opus-4-7", "openai/gpt-5"])
    end
  end
end
