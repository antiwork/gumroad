# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Gumhead::MessagesController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: @user)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
    Feature.activate_user(:gumhead, @user)

    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("GUMHEAD_UPSTREAM_API_KEY").and_return("sk-or-test")
    allow(GlobalConfig).to receive(:get).with("GUMHEAD_OAUTH_APPLICATION_UIDS", "").and_return(@app.uid)

    request.headers["Authorization"] = "Bearer #{@token.token}"
  end

  after do
    $redis.del(RedisKey.gumhead_gateway_throttle(@user.id))
    $redis.del(RedisKey.gumhead_gateway_in_flight(@user.id))
  end

  let(:messages_url) { "https://openrouter.ai/api/v1/messages" }
  let(:count_tokens_url) { "https://openrouter.ai/api/v1/messages/count_tokens" }
  let(:request_payload) do
    { model: "gumhead-chat", max_tokens: 64, messages: [{ role: "user", content: "Hi" }] }
  end
  let(:anthropic_response) do
    {
      id: "msg_test",
      type: "message",
      model: "claude-sonnet-5",
      content: [{ type: "text", text: "Hello!" }],
      usage: {
        input_tokens: 50,
        output_tokens: 7,
        cache_creation_input_tokens: 3,
        cache_creation: { ephemeral_5m_input_tokens: 1, ephemeral_1h_input_tokens: 2 },
        cache_read_input_tokens: 11,
      },
    }
  end

  def post_messages(payload = request_payload)
    post :create, body: payload.to_json, as: :json
  end

  describe "authentication and gating" do
    it "rejects a request without a valid access token, in the error envelope" do
      request.headers["Authorization"] = "Bearer nope"

      post_messages

      expect(response.status).to eq(401)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("authentication_error")
    end

    it "rejects a token sent as a query parameter" do
      request.headers["Authorization"] = nil

      post :create, params: { access_token: @token.token }, body: request_payload.to_json, as: :json

      expect(response.status).to eq(401)
    end

    it "rejects a token sent in the request body instead of the header" do
      post_messages(request_payload.merge(access_token: @token.token))

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["message"]).to include("Authorization header")
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    it "rejects a seller without the gumhead feature" do
      Feature.deactivate_user(:gumhead, @user)

      post_messages

      expect(response.status).to eq(403)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("permission_error")
    end

    it "refuses to proxy when the server-side key is not configured" do
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_ANTHROPIC_API_KEY").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_UPSTREAM_API_KEY").and_return(nil)

      post_messages

      expect(response.status).to eq(503)
    end

    it "rejects a token from an OAuth application outside the allowlist" do
      foreign_app = create(:oauth_application, owner: @user)
      foreign_token = create("doorkeeper/access_token", application: foreign_app, resource_owner_id: @user.id, scopes: "account")
      request.headers["Authorization"] = "Bearer #{foreign_token.token}"

      post_messages

      expect(response.status).to eq(403)
      expect(JSON.parse(response.body)["error"]["message"]).to include("OAuth application")
    end

    it "throttles once the hourly request budget is spent" do
      $redis.setex(
        RedisKey.gumhead_gateway_throttle(@user.id),
        described_class::GATEWAY_REQUESTS_PERIOD_WINDOW.to_i,
        described_class::GATEWAY_REQUESTS_PER_PERIOD,
      )

      post_messages

      expect(response.status).to eq(429)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("rate_limit_error")
      expect(response.headers["Retry-After"]).to be_present
    end

    it "repairs an hourly throttle key that lost its expiry" do
      $redis.set(RedisKey.gumhead_gateway_throttle(@user.id), 3)
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect($redis.ttl(RedisKey.gumhead_gateway_throttle(@user.id))).to be > 0
    end

    it "rejects a request past the concurrent in-flight limit and frees the probe slot" do
      key = RedisKey.gumhead_gateway_in_flight(@user.id)
      described_class::MAX_IN_FLIGHT_REQUESTS.times { |i| $redis.zadd(key, Time.current.to_f, "lease-#{i}") }

      post_messages

      expect(response.status).to eq(429)
      expect(WebMock).not_to have_requested(:post, messages_url)
      # The probe's own lease is removed; the active ones stay.
      expect($redis.zcard(key)).to eq(described_class::MAX_IN_FLIGHT_REQUESTS)
    end

    it "ages expired leases out of the in-flight set" do
      key = RedisKey.gumhead_gateway_in_flight(@user.id)
      stale = Time.current.to_f - described_class::IN_FLIGHT_TTL.to_i - 60
      described_class::MAX_IN_FLIGHT_REQUESTS.times { |i| $redis.zadd(key, stale, "dead-#{i}") }
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
    end
  end

  describe "flag-bit group gating (gumroad-private#2433)" do
    # :gumhead is actor-enabled for @user in the shared before; drop that so
    # coverage exercises only the flag-bit group path, not the stale actor gate.
    before do
      Feature.deactivate_user(:gumhead, @user)
      Flipper.enable_group(:gumhead, :gumhead_beta)
    end

    after do
      Flipper.disable_group(:gumhead, :gumhead_beta)
      @user.update!(gumhead_enabled: false)
    end

    it "rejects a seller without the flag bit" do
      post_messages

      expect(response.status).to eq(403)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("permission_error")
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    it "serves a seller with the flag bit through the group" do
      @user.update!(gumhead_enabled: true)
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["content"].first["text"]).to eq("Hello!")
      expect(GumheadUsageEvent.sole.user).to eq(@user)
    end
  end

  describe "request validation" do
    it "rejects a malformed JSON body with the gateway's error envelope" do
      post :create, body: "not json", as: :json

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("invalid_request_error")
    end

    # Same guard for a body sent without the JSON content type, where the
    # params parser never runs and load_body does the rejecting.
    it "rejects a non-JSON body" do
      post :create, body: "not json"

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("invalid_request_error")
    end

    it "rejects server-side tools" do
      post_messages(request_payload.merge(tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }]))

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["message"]).to include("Server-side tools")
    end

    it "allows plain client tools" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(tools: [{ name: "read_folder", input_schema: { type: "object" } }]))

      expect(response.status).to eq(200)
    end

    it "rejects a body over the size limit" do
      stub_const("#{described_class}::MAX_BODY_BYTES", 10)

      post_messages

      expect(response.status).to eq(400)
    end

    it "rejects a model outside the allowlist" do
      post_messages(request_payload.merge(model: "gpt-5.5"))

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["message"]).to include("not available")
    end

    it "rejects a Claude SKU outside the default family allowlist" do
      post_messages(request_payload.merge(model: "claude-fable-5"))

      expect(response.status).to eq(400)
    end

    it "rejects max_tokens over the per-request ceiling" do
      post_messages(request_payload.merge(max_tokens: described_class::MAX_TOKENS_PER_REQUEST + 1))

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["message"]).to include("max_tokens")
    end

    it "rejects a non-integer max_tokens instead of raising" do
      post_messages(request_payload.merge(max_tokens: { "sneaky" => true }))

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("invalid_request_error")
    end

    it "rejects a negative max_tokens" do
      post_messages(request_payload.merge(max_tokens: -64_000))

      expect(response.status).to eq(400)
    end

    # The runtime sends its full max_tokens ceiling on buffered calls too,
    # so a buffered request with a large ceiling must pass.
    it "allows a large max_tokens on a buffered call" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(max_tokens: described_class::MAX_TOKENS_PER_REQUEST))

      expect(response.status).to eq(200)
    end

    # Anthropic bills a timed-out buffered generation up to the max_tokens
    # it was sent, so the forwarded ceiling must never exceed what the
    # timeout window (and therefore the synthetic charge) can cover.
    it "clamps the forwarded max_tokens on a buffered call to the timeout-window ceiling" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(max_tokens: described_class::MAX_TOKENS_PER_REQUEST))

      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        JSON.parse(req.body)["max_tokens"] == described_class::MAX_BUFFERED_OUTPUT_TOKENS
      }
    end

    it "forwards a buffered max_tokens under the timeout-window ceiling untouched" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(max_tokens: 64))

      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        JSON.parse(req.body)["max_tokens"] == 64
      }
    end

    it "does not clamp max_tokens when streaming" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 5 }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(stream: true, max_tokens: described_class::MAX_TOKENS_PER_REQUEST))

      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        JSON.parse(req.body)["max_tokens"] == described_class::MAX_TOKENS_PER_REQUEST
      }
    end

    it "allows large outputs when streaming" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 12 }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(max_tokens: described_class::MAX_TOKENS_PER_REQUEST, stream: true))

      expect(response.status).to eq(200)
      expect(WebMock).to have_requested(:post, messages_url)
    end

    it "charges the prompt when an accepted stream never reports usage" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 21 }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(stream: true))

      event = GumheadUsageEvent.sole
      expect(event.input_tokens).to eq(21)
      expect(event.output_tokens).to eq(0)
    end

    it "rejects pricing modifiers the ledger cannot weight" do
      post_messages(request_payload.merge(speed: "fast"))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(inference_geo: "us"))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(fallbacks: [{ model: "claude-opus-5" }]))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(plugins: [{ id: "web" }]))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(models: ["x-ai/grok-4.6"]))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(service_tier: "priority"))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(provider: { sort: "price" }))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(route: "fallback"))
      expect(response.status).to eq(400)
    end

    # The runtime's real header, verbatim: every one of these must survive,
    # or its body fields come back as "Extra inputs are not permitted".
    it "forwards the runtime's beta features untouched" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })
      runtime_betas = "claude-code-20250219,interleaved-thinking-2025-05-14,thinking-token-count-2026-05-13," \
                      "context-management-2025-06-27,prompt-caching-scope-2026-01-05," \
                      "mid-conversation-system-2026-04-07,advisor-tool-2026-03-01,effort-2025-11-24"
      request.headers["anthropic-beta"] = runtime_betas

      post_messages

      expect(response.status).to eq(200)
      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        req.headers["Anthropic-Beta"] == runtime_betas
      }
    end

    it "drops beta features that could move spend outside the ledger" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })
      request.headers["anthropic-beta"] = "context-management-2025-06-27, server-side-fallback-2026-07-01"

      post_messages

      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        req.headers["Anthropic-Beta"] == "context-management-2025-06-27"
      }
    end
  end

  describe "buffered forwarding" do
    it "proxies to the upstream with the gateway key and records usage" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.except(:model).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["content"].first["text"]).to eq("Hello!")
      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        req.headers["Authorization"] == "Bearer sk-or-test" && req.headers["X-Api-Key"].nil?
      }

      event = GumheadUsageEvent.sole
      expect(event.user).to eq(@user)
      expect(event.model).to eq("x-ai/grok-4.6")
      expect(event.input_tokens).to eq(50)
      expect(event.output_tokens).to eq(7)
      expect(event.cache_creation_input_tokens).to eq(3)
      expect(event.cache_creation_1h_input_tokens).to eq(2)
      expect(event.cache_read_input_tokens).to eq(11)
    end

    it "keeps an upstream error's status and retry timing but mints its message" do
      stub_request(:post, messages_url)
        .to_return(status: 429, body: { type: "error", error: { type: "rate_limit_error", message: "Slow down" } }.to_json, headers: { "Retry-After" => "13" })

      post_messages

      expect(response.status).to eq(429)
      expect(response.headers["Retry-After"]).to eq("13")
      expect(JSON.parse(response.body)["error"]["message"]).to eq(described_class::UPSTREAM_ERRORS.fetch(:rate_limited).last)
      expect(response.body).not_to include("Slow down")
      expect(GumheadUsageEvent.count).to eq(0)
    end

    it "returns 502 when Anthropic is unreachable" do
      stub_request(:post, messages_url).to_raise(HTTP::ConnectionError)

      post_messages

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("api_error")
    end

    # A slow buffered generation and a network stall are indistinguishable
    # past TCP connect, and Anthropic bills abandoned generations — so a
    # post-connect timeout charges the bounded worst case, with the input
    # counted exactly via the free count_tokens endpoint.
    it "charges the bounded worst case for a post-connect timeout" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 37 }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(502)
      event = GumheadUsageEvent.sole
      expect(event.output_tokens).to eq(request_payload[:max_tokens])
      expect(event.input_tokens).to eq(37)
    end

    # A large ceiling is charged at what the model could emit in the time
    # the call actually had — here the stub fails instantly, so one second.
    it "charges a timeout by elapsed time, not by the max_tokens ceiling" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 12 }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(max_tokens: described_class::MAX_TOKENS_PER_REQUEST))

      expect(GumheadUsageEvent.sole.output_tokens).to eq(described_class::TIMEOUT_OUTPUT_TOKENS_PER_SECOND)
    end

    it "counts output_config in the timeout charge" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 90 }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(output_config: { format: { type: "json_schema", schema: { type: "object" } } }))

      expect(WebMock).to have_requested(:post, count_tokens_url).with { |req| req.body.include?("output_config") }
      expect(GumheadUsageEvent.sole.input_tokens).to eq(90)
    end

    it "charges timed-out cached prompts at the cache-write rate" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 80 }.to_json, headers: { "Content-Type" => "application/json" })
      cached_payload = request_payload.merge(
        system: [{ type: "text", text: "You are Gumhead.", cache_control: { type: "ephemeral" } }],
      )

      post_messages(cached_payload)

      event = GumheadUsageEvent.sole
      expect(event.input_tokens).to eq(0)
      expect(event.cache_creation_input_tokens).to eq(80)
    end

    # The cache check walks the parsed body, so a unicode-escaped key
    # cannot dodge the cache-write rate.
    it "detects cache_control hidden behind unicode escapes" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 44 }.to_json, headers: { "Content-Type" => "application/json" })
      escaped_body = request_payload.to_json.sub("\"messages\"", "\"system\":[{\"type\":\"text\",\"text\":\"hi\",\"cache_contr\\u006fl\":{\"type\":\"ephemeral\"}}],\"messages\"")

      post :create, body: escaped_body, as: :json

      event = GumheadUsageEvent.sole
      expect(event.cache_creation_input_tokens).to eq(44)
      expect(event.input_tokens).to eq(0)
    end

    it "renders a 502 envelope and charges when TLS fails after success headers" do
      stub_request(:post, messages_url).to_raise(OpenSSL::SSL::SSLError)
      # An SSL failure during the initial call has no response headers, so
      # nothing is charged — the accepted-response case is covered by the
      # lost-body branch, which shares the same evidence rule.
      post_messages

      expect(response.status).to eq(502)
      expect(GumheadUsageEvent.count).to eq(0)
    end

    it "falls back to a conservative byte estimate when count_tokens also fails" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)
      stub_request(:post, count_tokens_url).to_raise(HTTP::ConnectionError)

      post_messages

      expect(response.status).to eq(502)
      expect(GumheadUsageEvent.sole.input_tokens).to eq(request_payload.merge(model: "x-ai/grok-4.6").to_json.bytesize)
    end

    it "charges nothing when the connection itself times out" do
      stub_request(:post, messages_url).to_raise(HTTP::ConnectTimeoutError)

      post_messages

      expect(response.status).to eq(502)
      expect(GumheadUsageEvent.count).to eq(0)
    end

    it "does not meter an unbilled pre-output refusal" do
      refusal = anthropic_response.merge(stop_reason: "refusal", content: [])
      stub_request(:post, messages_url)
        .to_return(status: 200, body: refusal.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
      expect(GumheadUsageEvent.count).to eq(0)
    end
  end

  describe "streaming" do
    let(:sse_body) do
      [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":9}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":42,"input_tokens":60,"cache_read_input_tokens":14}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ].join
    end

    it "passes the SSE stream through untouched and records the scanned usage" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: sse_body, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(response.headers["Content-Type"]).to include("text/event-stream")
      expect(response.body).to eq(sse_body)

      event = GumheadUsageEvent.sole
      expect(event.model).to eq("claude-sonnet-5")
      # message_delta carries cumulative counts and wins over message_start.
      expect(event.input_tokens).to eq(60)
      expect(event.output_tokens).to eq(42)
      expect(event.cache_creation_input_tokens).to eq(2)
      expect(event.cache_read_input_tokens).to eq(14)
    end

    it "floors the recorded output at the delta count when the final message_delta never arrives" do
      truncated = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"He"}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ll"}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"o"}}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: truncated, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      event = GumheadUsageEvent.sole
      expect(event.input_tokens).to eq(50)
      expect(event.output_tokens).to eq(3)
      # An EOF without message_stop must not read as a clean close.
      expect(response.body).to include("event: error")
    end

    it "keeps message_start counts when message_delta sends null usage fields" do
      stream = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1,"cache_read_input_tokens":9}}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":42,"input_tokens":null,"cache_read_input_tokens":null}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: stream, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      event = GumheadUsageEvent.sole
      expect(event.input_tokens).to eq(50)
      expect(event.output_tokens).to eq(42)
      expect(event.cache_read_input_tokens).to eq(9)
    end

    it "does not append an error frame to a stream that ended with message_stop" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: sse_body, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(response.body).not_to include("event: error")
    end

    it "floors interrupted output by streamed bytes when one delta carries many tokens" do
      long_text = "a" * 400
      truncated = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"#{long_text}"}}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: truncated, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(GumheadUsageEvent.sole.output_tokens).to eq(100)
    end

    it "does not meter a streamed pre-output refusal" do
      refusal_stream = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":1}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: refusal_stream, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(GumheadUsageEvent.count).to eq(0)
    end

    it "charges the prompt when the stream header wait times out" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 33 }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(502)
      event = GumheadUsageEvent.sole
      expect(event.input_tokens).to eq(33)
      expect(event.output_tokens).to eq(0)
    end

    it "returns a buffered 502 when the upstream connection fails before the stream starts" do
      stub_request(:post, messages_url).to_raise(HTTP::ConnectionError)

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("api_error")
    end

    it "reports an upstream socket reset to the client instead of treating it as a disconnect" do
      chunks = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}\n\n),
      ]
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      allow_any_instance_of(HTTP::Response::Body).to receive(:readpartial) do
        chunks.empty? ? raise(Errno::ECONNRESET) : chunks.shift
      end

      allow(Rails.logger).to receive(:warn).and_call_original
      post_messages(request_payload.merge(stream: true))

      expect(Rails.logger).to have_received(:warn).with(a_string_including("Gumhead gateway upstream error"))
      expect(response.body).to include("Hel")
      # A truncated reply must not look finished: the runtime reads this
      # frame and retries instead of accepting half an answer.
      expect(response.body).to include("event: error")
      expect(GumheadUsageEvent.sole.input_tokens).to eq(50)
    end

    it "answers a completed blank stream as retryable even when the socket resets at the final read" do
      blank = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ]
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      allow_any_instance_of(HTTP::Response::Body).to receive(:readpartial) do
        blank.empty? ? raise(Errno::ECONNRESET) : blank.shift
      end

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(described_class::UPSTREAM_ERRORS.fetch(:busy).last)
    end

    it "does not append an error frame when the socket resets after message_stop" do
      chunks = sse_body.chars.each_slice(512).map(&:join)
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      allow_any_instance_of(HTTP::Response::Body).to receive(:readpartial) do
        chunks.empty? ? raise(Errno::ECONNRESET) : chunks.shift
      end

      post_messages(request_payload.merge(stream: true))

      expect(response.body).to include("event: message_stop")
      expect(response.body).not_to include("event: error")
      expect(GumheadUsageEvent.sole.output_tokens).to eq(42)
    end

    it "appends the error frame when the reset lands between message_stop and its delimiter" do
      chunks = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}),
      ]
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      allow_any_instance_of(HTTP::Response::Body).to receive(:readpartial) do
        chunks.empty? ? raise(Errno::ECONNRESET) : chunks.shift
      end

      post_messages(request_payload.merge(stream: true))

      # The SSE contract dispatches an event only at its blank-line
      # delimiter; without it the client never saw message_stop.
      expect(response.body).to include("event: error")
    end

    it "does not append an error frame to a complete CRLF-framed stream" do
      crlf = [
        %(event: message_start\r\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\r\n\r\n),
        %(event: content_block_delta\r\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\r\n\r\n),
        %(event: message_delta\r\ndata: {"type":"message_delta","usage":{"output_tokens":42,"input_tokens":60}}\r\n\r\n),
        %(event: message_stop\r\ndata: {"type":"message_stop"}\r\n\r\n),
      ]
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      allow_any_instance_of(HTTP::Response::Body).to receive(:readpartial) do
        crlf.empty? ? raise(Errno::ECONNRESET) : crlf.shift
      end

      post_messages(request_payload.merge(stream: true))

      expect(response.body).to include("message_stop")
      expect(response.body).not_to include("event: error")
    end

    it "appends the error frame when a CRLF stream resets after message_stop's own line ending" do
      chunks = [
        %(event: message_start\r\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\r\n\r\n),
        %(event: content_block_delta\r\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\r\n\r\n),
        %(event: message_stop\r\ndata: {"type":"message_stop"}\r\n),
      ]
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      allow_any_instance_of(HTTP::Response::Body).to receive(:readpartial) do
        chunks.empty? ? raise(Errno::ECONNRESET) : chunks.shift
      end

      post_messages(request_payload.merge(stream: true))

      # One CRLF ends the data line; the blank line never arrived, so the
      # client never dispatched message_stop.
      expect(response.body).to include("event: error")
    end

    it "reports a wrapped connection error to the client mid-stream" do
      chunks = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}\n\n),
      ]
      stub_request(:post, messages_url)
        .to_return(status: 200, body: "", headers: { "Content-Type" => "text/event-stream" })
      allow_any_instance_of(HTTP::Response::Body).to receive(:readpartial) do
        chunks.empty? ? raise(HTTP::ConnectionError, "connection reset") : chunks.shift
      end

      post_messages(request_payload.merge(stream: true))

      expect(response.body).to include("Hel")
      expect(response.body).to include("event: error")
    end

    it "logs a stream that ends without message_stop" do
      truncated = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: truncated, headers: { "Content-Type" => "text/event-stream" })

      allow(Rails.logger).to receive(:warn).and_call_original
      post_messages(request_payload.merge(stream: true))

      expect(Rails.logger).to have_received(:warn).with(a_string_including("stream ended without message_stop"))
      expect(response.body).to include("event: error")
    end

    it "renders an upstream rejection as a buffered error instead of a stream" do
      stub_request(:post, messages_url)
        .to_return(status: 401, body: { type: "error", error: { type: "authentication_error", message: "bad key" } }.to_json)

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(401)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(described_class::UPSTREAM_ERRORS.fetch(:credentials).last)
      expect(response.body).not_to include("bad key")
      expect(GumheadUsageEvent.count).to eq(0)
    end
  end

  describe "daily token caps" do
    it "rejects the request once the daily output cap is spent" do
      GumheadUsageEvent.create!(
        user: @user,
        model: "claude-sonnet-5",
        output_tokens: described_class::DEFAULT_DAILY_OUTPUT_TOKEN_CAP,
      )

      post_messages

      expect(response.status).to eq(429)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("rate_limit_error")
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    it "counts cache tokens toward the input cap at their cost weight" do
      GumheadUsageEvent.create!(
        user: @user,
        model: "claude-sonnet-5",
        cache_read_input_tokens: (described_class::DEFAULT_DAILY_INPUT_TOKEN_CAP / GumheadUsageEvent::CACHE_READ_COST_MULTIPLIER).to_i,
      )

      post_messages

      expect(response.status).to eq(429)
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    it "ignores spend from previous days" do
      travel_to(2.days.ago) do
        GumheadUsageEvent.create!(
          user: @user,
          model: "claude-sonnet-5",
          output_tokens: described_class::DEFAULT_DAILY_OUTPUT_TOKEN_CAP,
        )
      end
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
    end
  end

  describe "POST count_tokens" do
    it "proxies without writing a ledger row" do
      stub_request(:post, count_tokens_url)
        .to_return(status: 200, body: { input_tokens: 123 }.to_json, headers: { "Content-Type" => "application/json" })

      post :count_tokens, body: request_payload.to_json, as: :json

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["input_tokens"]).to eq(123)
      expect(GumheadUsageEvent.count).to eq(0)
    end

    # The Anthropic host has a real count_tokens, so a 404 there is an
    # answer, not a missing path.
    it "passes through a 404 from Anthropic count_tokens" do
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_UPSTREAM_API_BASE", described_class::DEFAULT_UPSTREAM_API_BASE)
        .and_return("https://api.anthropic.com/v1")
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-chat" => "claude-sonnet-5" }.to_json)
      stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
        .to_return(status: 404, body: { type: "error", error: { type: "not_found_error", message: "Not Found" } }.to_json)

      post :count_tokens, body: request_payload.to_json, as: :json

      expect(response.status).to eq(404)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("not_found_error")
    ensure
      $redis.del(RedisKey.gumhead_model_map)
    end

    it "shares the concurrent in-flight limit" do
      key = RedisKey.gumhead_gateway_in_flight(@user.id)
      described_class::MAX_IN_FLIGHT_REQUESTS.times { |i| $redis.zadd(key, Time.current.to_f, "lease-#{i}") }

      post :count_tokens, body: request_payload.to_json, as: :json

      expect(response.status).to eq(429)
      expect(WebMock).not_to have_requested(:post, count_tokens_url)
    end
  end

  describe "upstream hop" do
    let(:anthropic_messages_url) { "https://api.anthropic.com/v1/messages" }

    def use_anthropic_base
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_UPSTREAM_API_BASE", described_class::DEFAULT_UPSTREAM_API_BASE)
        .and_return("https://api.anthropic.com/v1")
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_ANTHROPIC_API_KEY").and_return("sk-ant-gateway-test")
    end

    it "rewrites a role id to its mapped model before forwarding" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.except(:model).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        JSON.parse(req.body)["model"] == "x-ai/grok-4.6"
      }
      expect(GumheadUsageEvent.sole.model).to eq("x-ai/grok-4.6")
    end

    it "rejects the Claude names older builds sent" do
      post_messages(request_payload.merge(model: "claude-sonnet-5"))

      expect(response.status).to eq(400)
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    it "rejects a suffixed role id instead of treating it as a prefix" do
      post_messages(request_payload.merge(model: "gumhead-chat-extra"))

      expect(response.status).to eq(400)
    end

    it "rejects a role id that is missing from the allowlist" do
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_ALLOWED_MODEL_PREFIXES", described_class::DEFAULT_ALLOWED_MODEL_PREFIXES)
        .and_return("gumhead-chat")

      post_messages(request_payload.merge(model: "gumhead-status"))

      expect(response.status).to eq(400)
    end

    # A role id is never a real model, so a map entry that stops changing
    # it must fail closed rather than forward a client-controlled name.
    it "rejects a role id whose map entry is an identity mapping" do
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-chat" => "gumhead-chat" }.to_json)

      post_messages

      expect(response.status).to eq(400)
      expect(WebMock).not_to have_requested(:post, messages_url)
    ensure
      $redis.del(RedisKey.gumhead_model_map)
    end

    it "refuses to proxy when no upstream key is set for the default host" do
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_UPSTREAM_API_KEY").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_ANTHROPIC_API_KEY").and_return(nil)

      post_messages

      expect(response.status).to eq(503)
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    it "sends a bearer token to OpenRouter and omits x-api-key" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        req.headers["Authorization"] == "Bearer sk-or-test" && req.headers["X-Api-Key"].nil?
      }
    end

    # The Anthropic secret stays on api.anthropic.com, under the header
    # that host requires; a mapped role still rewrites there.
    it "uses x-api-key and the Anthropic fallback key on the Anthropic host" do
      use_anthropic_base
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_UPSTREAM_API_KEY").and_return(nil)
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-chat" => "claude-sonnet-5" }.to_json)
      stub_request(:post, anthropic_messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(WebMock).to have_requested(:post, anthropic_messages_url).with { |req|
        req.headers["X-Api-Key"] == "sk-ant-gateway-test" && req.headers["Authorization"].nil? &&
          JSON.parse(req.body)["model"] == "claude-sonnet-5"
      }
    ensure
      $redis.del(RedisKey.gumhead_model_map)
    end

    it "does not send the Anthropic key to a non-Anthropic host" do
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_UPSTREAM_API_KEY").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_ANTHROPIC_API_KEY").and_return("sk-ant-gateway-test")

      post_messages

      expect(response.status).to eq(503)
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    it "returns a synthetic token count when upstream count_tokens is missing" do
      stub_request(:post, count_tokens_url)
        .to_return(status: 404, body: { type: "error", error: { type: "not_found_error", message: "Not Found" } }.to_json)

      post :count_tokens, body: request_payload.to_json, as: :json

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["input_tokens"]).to eq(request_payload.merge(model: "x-ai/grok-4.6").to_json.bytesize)
      expect(GumheadUsageEvent.count).to eq(0)
    end
  end


  describe "minted upstream errors" do
    def minted(key) = described_class::UPSTREAM_ERRORS.fetch(key).last

    def stub_upstream_error(status:, message:, headers: {})
      stub_request(:post, messages_url).to_return(
        status:,
        body: { type: "error", error: { type: "invalid_request_error", message: } }.to_json,
        headers: { "Content-Type" => "application/json" }.merge(headers),
      )
    end

    # No spend-limit shape may be reported as a transient retry.
    [
      ["a self-set organization limit", 400, "You have reached your specified API usage limits. You will regain access on 2026-09-01 at 00:00 UTC."],
      ["a workspace limit", 400, "You have reached your specified workspace API usage limits."],
      ["a tier spend cap", 429, "You have reached your API usage limits: your organization has crossed its monthly API usage threshold."],
      ["exhausted credit", 402, "Insufficient credits."],
    ].each do |label, status, message|
      it "mints an out-of-budget error for #{label}" do
        stub_upstream_error(status:, message:)

        post_messages

        expect(response.status).to eq(status)
        expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:out_of_budget))
        expect(response.body).not_to include("usage limits")
        expect(response.body).not_to include("Insufficient credits")
      end
    end

    it "mints a credentials error for an upstream 403 that names the key" do
      stub_upstream_error(status: 403, message: "Your API key is not permitted")

      post_messages

      expect(response.status).to eq(403)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:credentials))
    end

    # Guardrails, model allowlists, and budget caps all answer 403; calling
    # those a rejected key would send ops looking at the wrong thing, and a
    # fixed string would say less than the provider already did.
    ["Blocked by a guardrail policy", "This model is not permitted", "Permission denied for this route"].each do |message|
      it "does not blame credentials for a 403 saying #{message.inspect}" do
        stub_upstream_error(status: 403, message:)

        post_messages

        expect(response.status).to eq(403)
        expect(JSON.parse(response.body)["error"]["message"]).to eq(message)
      end
    end

    it "keeps a client-correctable 400 as the provider wrote it" do
      stub_upstream_error(status: 400, message: "max_tokens: Field required")

      post_messages

      expect(response.status).to eq(400)
      expect(response.body).to include("max_tokens: Field required")
    end

    it "reads OpenRouter's 403 workspace budget cap as out of budget" do
      stub_upstream_error(status: 403, message: "Workspace monthly budget of $500.00 exceeded. Contact your org admin.")

      post_messages

      expect(response.status).to eq(403)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:out_of_budget))
    end

    it "tells the runtime not to retry a spend limit it would otherwise retry" do
      stub_upstream_error(status: 429, message: "You have reached your specified API usage limits.")

      post_messages

      expect(response.status).to eq(429)
      expect(response.headers["x-should-retry"]).to eq("false")
    end

    it "leaves a real rate limit retryable" do
      stub_upstream_error(status: 429, message: "Per-minute rate limit exceeded", headers: { "Retry-After" => "9" })

      post_messages

      expect(response.headers["x-should-retry"]).to be_nil
      expect(response.headers["Retry-After"]).to eq("9")
    end

    it "mints a busy error for an upstream overload" do
      stub_upstream_error(status: 529, message: "Overloaded")

      post_messages

      expect(response.status).to eq(529)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:busy))
    end

    it "separates a real rate limit from a spend limit on the same status" do
      stub_upstream_error(status: 429, message: "Number of request tokens has exceeded your per-minute rate limit")

      post_messages

      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:rate_limited))
    end

    it "keeps a per-minute quota transient rather than reading it as a budget" do
      stub_upstream_error(status: 429, message: "You have exceeded your per-minute request quota")

      post_messages

      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:rate_limited))
    end

    it "trusts the structured spend-limit code over the wording" do
      stub_request(:post, messages_url).to_return(
        status: 429,
        body: {
          type: "error",
          error: { type: "rate_limit_error", message: "Access paused.", details: { error_code: "enforced_spend_limit_reached" } },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

      post_messages

      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:out_of_budget))
    end

    it "mints instead of raising when the upstream puts a bare string in error" do
      stub_request(:post, messages_url)
        .to_return(status: 401, body: { error: "Unauthorized" }.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(401)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:credentials))
    end

    it "logs the upstream text it withheld from the seller" do
      stub_upstream_error(status: 403, message: "Your key is not permitted")
      allow(Rails.logger).to receive(:warn)

      post_messages

      expect(Rails.logger).to have_received(:warn).with(/status=403 .*Your key is not permitted/)
    end

    # The minted envelope replaces the body that carried this, and it is
    # the only handle for finding the failure in the provider's logs.
    it "logs the provider's request id alongside the withheld text" do
      stub_request(:post, messages_url).to_return(
        status: 429,
        body: { type: "error", error: { type: "rate_limit_error", message: "Slow down" }, request_id: "req_018EeWyXxfu5" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
      allow(Rails.logger).to receive(:warn)

      post_messages

      expect(Rails.logger).to have_received(:warn).with(/request_id=req_018EeWyXxfu5/)
    end

    it "mints for an upstream body that is not JSON at all" do
      stub_request(:post, messages_url).to_return(status: 502, body: "<html>Bad Gateway</html>")

      post_messages

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(minted(:busy))
      expect(response.body).not_to include("html")
    end

    it "leaves a successful reply untouched" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["content"].first["text"]).to eq("Hello!")
      expect(GumheadUsageEvent.count).to eq(1)
    end
  end

  describe "empty upstream replies" do
    let(:blank_sse) do
      [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"x-ai/grok-4.6","usage":{"input_tokens":40,"output_tokens":0}}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0,"input_tokens":40}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ].join
    end

    it "answers a completed blank stream as retryable instead of committing it" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: blank_sse, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(502)
      expect(response.headers["Content-Type"]).not_to include("event-stream")
      expect(JSON.parse(response.body)["error"]["message"]).to eq(described_class::UPSTREAM_ERRORS.fetch(:busy).last)
    end

    it "answers a thinking-only completed stream as retryable" do
      thinking_sse = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"x-ai/grok-4.6","usage":{"input_tokens":40,"output_tokens":0}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9,"input_tokens":40}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: thinking_sse, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(502)
    end

    it "meters what a rejected blank stream reported" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: blank_sse, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(GumheadUsageEvent.sole.input_tokens).to eq(40)
    end

    it "passes a refusal stream through as it arrived" do
      refusal_sse = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"x-ai/grok-4.6","usage":{"input_tokens":40,"output_tokens":0}}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0,"input_tokens":40}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: refusal_sse, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(response.headers["Content-Type"]).to include("event-stream")
      expect(response.body).to eq(refusal_sse)
    end

    it "streams a tool_use-only stream through byte for byte" do
      tool_sse = [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"x-ai/grok-4.6","usage":{"input_tokens":40,"output_tokens":0}}}\n\n),
        %(event: content_block_start\ndata: {"type":"content_block_start","content_block":{"type":"tool_use","id":"t1","name":"read_folder"}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12,"input_tokens":40}}\n\n),
        %(event: message_stop\ndata: {"type":"message_stop"}\n\n),
      ].join
      stub_request(:post, messages_url)
        .to_return(status: 200, body: tool_sse, headers: { "Content-Type" => "text/event-stream" })

      post_messages(request_payload.merge(stream: true))

      expect(response.headers["Content-Type"]).to include("event-stream")
      expect(response.body).to eq(tool_sse)
    end

    def empty_reply(content:, output_tokens: 0)
      {
        id: "msg_e", type: "message", role: "assistant", model: "x-ai/grok-4.6",
        content:, stop_reason: "end_turn",
        usage: { input_tokens: 40, output_tokens: },
      }
    end

    it "answers a 200 with no output as retryable instead of passing a blank turn through" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: empty_reply(content: []).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(described_class::UPSTREAM_ERRORS.fetch(:busy).last)
    end

    it "still meters the input the empty reply reported" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: empty_reply(content: []).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(GumheadUsageEvent.sole.input_tokens).to eq(40)
    end

    it "treats blank text blocks as no output" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: empty_reply(content: [{ type: "text", text: "  " }]).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(502)
    end

    # Billing and substance are different facts: a blank reply can carry a
    # nonzero output count, and it is still a blank turn.
    it "catches a blank reply that billed output tokens" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: empty_reply(content: [], output_tokens: 1).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(502)
    end

    # A refusal legitimately ships empty content; the client handles it,
    # and retrying a refused prompt cannot succeed.
    it "passes a refusal through untouched" do
      body = empty_reply(content: []).merge(stop_reason: "refusal")
      stub_request(:post, messages_url)
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["stop_reason"]).to eq("refusal")
    end

    # A tool call is a normal loop step; converting it to an error would
    # break every agentic turn.
    it "passes a tool_use-only reply through untouched" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: empty_reply(content: [{ type: "tool_use", id: "t1", name: "read_folder", input: {} }], output_tokens: 0).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["content"].first["type"]).to eq("tool_use")
    end

    # The client renders neither the thinking nor the silence after it, so
    # a completed turn of pure deliberation is a blank turn.
    it "retries a thinking-only completed turn" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: empty_reply(content: [{ type: "thinking", thinking: "hm" }], output_tokens: 31).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(502)
    end

    it "passes thinking through when text accompanies it" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: empty_reply(content: [{ type: "thinking", thinking: "hm" }, { type: "text", text: "Done." }], output_tokens: 40).to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
    end

    it "leaves an unfinished stop reason alone even with no visible output" do
      body = empty_reply(content: [{ type: "thinking", thinking: "hm" }]).merge(stop_reason: "max_tokens")
      stub_request(:post, messages_url)
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
    end
  end

  describe "client version gate" do
    after { $redis.del(RedisKey.gumhead_client_versions) }

    def stub_upstream
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "does nothing while no minimum is set" do
      stub_upstream

      post_messages

      expect(response.status).to eq(200)
    end

    it "refuses a build below the minimum with the update message" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.2.0" }.to_json)
      request.headers["X-Gumhead-Version"] = "0.1.0"

      post_messages

      expect(response.status).to eq(426)
      expect(JSON.parse(response.body)["error"]["message"]).to eq(described_class::UPDATE_REQUIRED_MESSAGE)
      expect(WebMock).not_to have_requested(:post, messages_url)
    end

    # A missing header means the one released pre-header build, 0.1.0.
    it "gates the pre-header build once the minimum passes its version" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.2.0" }.to_json)

      post_messages

      expect(response.status).to eq(426)
    end

    it "serves a build at the minimum" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.2.0" }.to_json)
      request.headers["X-Gumhead-Version"] = "0.2.0"
      stub_upstream

      post_messages

      expect(response.status).to eq(200)
    end

    it "refuses a garbled version header once a minimum is set" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.2.0" }.to_json)
      request.headers["X-Gumhead-Version"] = "not-a-version"

      post_messages

      expect(response.status).to eq(426)
    end

    it "serves the pre-header build while the minimum is its version" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.1.0" }.to_json)
      stub_upstream

      post_messages

      expect(response.status).to eq(200)
    end

    it "serves a dev build regardless of the minimum" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.2.0" }.to_json)
      request.headers["X-Gumhead-Version"] = "dev"
      stub_upstream

      post_messages

      expect(response.status).to eq(200)
    end

    it "serves everyone when the configured minimum is not a version" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.2.x" }.to_json)
      request.headers["X-Gumhead-Version"] = "0.1.0"
      stub_upstream

      post_messages

      expect(response.status).to eq(200)
    end

    it "serves turns when the Redis read fails" do
      allow($redis).to receive(:get).and_call_original
      allow($redis).to receive(:get).with(RedisKey.gumhead_client_versions).and_raise(Redis::CannotConnectError)
      stub_upstream

      post_messages

      expect(response.status).to eq(200)
    end

    it "reports the configured versions to an authenticated client" do
      $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.1.0", "current" => "0.2.0" }.to_json)

      get :client_version

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)).to eq("min" => "0.1.0", "current" => "0.2.0")
    end

    it "reports an empty object while nothing is configured" do
      get :client_version

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)).to eq({})
    end

    it "requires a token for the version endpoint" do
      request.headers["Authorization"] = "Bearer nope"

      get :client_version

      expect(response.status).to eq(401)
    end

    it "answers the version endpoint even when the gateway key is unset" do
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_UPSTREAM_API_KEY").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_ANTHROPIC_API_KEY").and_return(nil)

      get :client_version

      expect(response.status).to eq(200)
    end
  end

  describe "live model map in Redis" do
    let(:openrouter_messages_url) { "https://openrouter.ai/api/v1/messages" }

    after { $redis.del(RedisKey.gumhead_model_map) }

    def use_openrouter_base
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_UPSTREAM_API_BASE", described_class::DEFAULT_UPSTREAM_API_BASE)
        .and_return("https://openrouter.ai/api/v1")
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_UPSTREAM_API_KEY").and_return("sk-or-test")
    end

    # Response without a model, so the ledger has to take the name from
    # the rewritten body. A stub naming the mapped model would pass with
    # the rewrite reverted.
    def stub_openrouter
      stub_request(:post, openrouter_messages_url)
        .to_return(status: 200, body: anthropic_response.except(:model).to_json, headers: { "Content-Type" => "application/json" })
    end

    def expect_forwarded_model(url, model)
      expect(WebMock).to have_requested(:post, url).with { |req|
        JSON.parse(req.body)["model"] == model
      }
    end

    it "serves the model a Redis write names, without a deploy" do
      use_openrouter_base
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-chat" => "openai/gpt-5.6-luna" }.to_json)
      stub_openrouter

      post_messages

      expect(response.status).to eq(200)
      expect_forwarded_model(openrouter_messages_url, "openai/gpt-5.6-luna")
      expect(GumheadUsageEvent.sole.model).to eq("openai/gpt-5.6-luna")
    end

    it "moves one role and leaves the rest on the built-in map" do
      use_openrouter_base
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-status" => "openai/gpt-5.6-luna" }.to_json)
      stub_openrouter

      post_messages(request_payload.merge(model: "gumhead-status"))
      post_messages(request_payload.merge(model: "gumhead-chat"))

      expect_forwarded_model(openrouter_messages_url, "openai/gpt-5.6-luna")
      expect_forwarded_model(openrouter_messages_url, "x-ai/grok-4.6")
    end

    it "outranks the deployed GUMHEAD_MODEL_MAP" do
      use_openrouter_base
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_MODEL_MAP")
        .and_return({ "gumhead-chat" => "x-ai/grok-4.5" }.to_json)
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-chat" => "openai/gpt-5.6-luna" }.to_json)
      stub_openrouter

      post_messages

      expect_forwarded_model(openrouter_messages_url, "openai/gpt-5.6-luna")
    end

    it "falls back to the deployed map once the Redis key is deleted" do
      use_openrouter_base
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_MODEL_MAP")
        .and_return({ "gumhead-chat" => "x-ai/grok-4.5" }.to_json)
      $redis.del(RedisKey.gumhead_model_map)
      stub_openrouter

      post_messages

      expect_forwarded_model(openrouter_messages_url, "x-ai/grok-4.5")
    end

    it "serves the deployed map and warns when the Redis value is not a JSON object" do
      use_openrouter_base
      $redis.set(RedisKey.gumhead_model_map, "x-ai/grok-4.5")
      stub_openrouter
      allow(Rails.logger).to receive(:warn)

      post_messages

      expect(response.status).to eq(200)
      expect(Rails.logger).to have_received(:warn).with(/not a JSON object/).at_least(:once)
      expect_forwarded_model(openrouter_messages_url, "x-ai/grok-4.6")
    end

    it "warns on a stored empty value instead of treating it as unset" do
      use_openrouter_base
      $redis.set(RedisKey.gumhead_model_map, "")
      stub_openrouter
      allow(Rails.logger).to receive(:warn)

      post_messages

      expect(response.status).to eq(200)
      expect(Rails.logger).to have_received(:warn).with(/not a JSON object/).at_least(:once)
      expect_forwarded_model(openrouter_messages_url, "x-ai/grok-4.6")
    end

    it "serves the deployed map when Redis is unreachable" do
      use_openrouter_base
      # Other services read $redis on this path; only the map read fails.
      allow($redis).to receive(:get).and_call_original
      allow($redis).to receive(:get).with(RedisKey.gumhead_model_map).and_raise(Redis::CannotConnectError)
      stub_openrouter

      post_messages

      expect(response.status).to eq(200)
      expect_forwarded_model(openrouter_messages_url, "x-ai/grok-4.6")
    end

    it "rewrites on an Anthropic upstream when Redis names a real model there" do
      allow(GlobalConfig).to receive(:get)
        .with("GUMHEAD_UPSTREAM_API_BASE", described_class::DEFAULT_UPSTREAM_API_BASE)
        .and_return("https://api.anthropic.com/v1")
      allow(GlobalConfig).to receive(:get).with("GUMHEAD_ANTHROPIC_API_KEY").and_return("sk-ant-gateway-test")
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-chat" => "claude-sonnet-4.5" }.to_json)
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect_forwarded_model("https://api.anthropic.com/v1/messages", "claude-sonnet-4.5")
    end

    it "records which source chose the model" do
      use_openrouter_base
      $redis.set(RedisKey.gumhead_model_map, { "gumhead-chat" => "openai/gpt-5.6-luna" }.to_json)
      stub_openrouter
      sources = []
      subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
        sources << payload[:gumhead_model_map_source]
      end

      begin
        post_messages
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(sources).to include("redis")
    end
  end
end
