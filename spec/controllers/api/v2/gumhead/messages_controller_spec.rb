# frozen_string_literal: true

require "spec_helper"

describe Api::V2::Gumhead::MessagesController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: @user)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
    Feature.activate_user(:gumhead, @user)

    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("GUMHEAD_ANTHROPIC_API_KEY").and_return("sk-ant-gateway-test")
    allow(GlobalConfig).to receive(:get).with("GUMHEAD_OAUTH_APPLICATION_UIDS", "").and_return(@app.uid)

    request.headers["Authorization"] = "Bearer #{@token.token}"
  end

  after do
    $redis.del(RedisKey.gumhead_gateway_throttle(@user.id))
    $redis.del(RedisKey.gumhead_gateway_in_flight(@user.id))
  end

  let(:messages_url) { "https://api.anthropic.com/v1/messages" }
  let(:count_tokens_url) { "https://api.anthropic.com/v1/messages/count_tokens" }
  let(:request_payload) do
    { model: "claude-sonnet-5", max_tokens: 64, messages: [{ role: "user", content: "Hi" }] }
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

    it "rejects a request past the concurrent in-flight limit and frees the probe slot" do
      $redis.setex(RedisKey.gumhead_gateway_in_flight(@user.id), 120, described_class::MAX_IN_FLIGHT_REQUESTS)

      post_messages

      expect(response.status).to eq(429)
      expect(WebMock).not_to have_requested(:post, messages_url)
      expect($redis.get(RedisKey.gumhead_gateway_in_flight(@user.id)).to_i).to eq(described_class::MAX_IN_FLIGHT_REQUESTS)
      # A rejected probe must not renew the stale counter's TTL, or retries
      # would keep a leaked counter alive forever.
      expect($redis.ttl(RedisKey.gumhead_gateway_in_flight(@user.id))).to be_between(1, 120)
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

    it "rejects pricing modifiers the ledger cannot weight" do
      post_messages(request_payload.merge(speed: "fast"))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(inference_geo: "us"))
      expect(response.status).to eq(400)

      post_messages(request_payload.merge(fallbacks: [{ model: "claude-opus-5" }]))
      expect(response.status).to eq(400)
    end

    it "forwards only allowlisted anthropic-beta features" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })
      request.headers["anthropic-beta"] = "interleaved-thinking-2025-05-14, server-side-fallback-2026-07-01"

      post_messages

      expect(response.status).to eq(200)
      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        req.headers["Anthropic-Beta"] == "interleaved-thinking-2025-05-14"
      }
    end
  end

  describe "buffered forwarding" do
    it "proxies to Anthropic with the server key and records usage" do
      stub_request(:post, messages_url)
        .to_return(status: 200, body: anthropic_response.to_json, headers: { "Content-Type" => "application/json" })

      post_messages

      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["content"].first["text"]).to eq("Hello!")
      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        req.headers["X-Api-Key"] == "sk-ant-gateway-test" && req.headers["Authorization"].nil?
      }

      event = GumheadUsageEvent.sole
      expect(event.user).to eq(@user)
      expect(event.model).to eq("claude-sonnet-5")
      expect(event.input_tokens).to eq(50)
      expect(event.output_tokens).to eq(7)
      expect(event.cache_creation_input_tokens).to eq(3)
      expect(event.cache_creation_1h_input_tokens).to eq(2)
      expect(event.cache_read_input_tokens).to eq(11)
    end

    it "passes an upstream error through with its status and body" do
      stub_request(:post, messages_url)
        .to_return(status: 429, body: { type: "error", error: { type: "rate_limit_error", message: "Slow down" } }.to_json)

      post_messages

      expect(response.status).to eq(429)
      expect(response.body).to include("Slow down")
      expect(GumheadUsageEvent.count).to eq(0)
    end

    it "returns 502 when Anthropic is unreachable" do
      stub_request(:post, messages_url).to_raise(HTTP::ConnectionError)

      post_messages

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("api_error")
    end

    it "charges the worst case when the upstream call times out" do
      stub_request(:post, messages_url).to_raise(HTTP::TimeoutError)

      post_messages

      expect(response.status).to eq(502)
      event = GumheadUsageEvent.sole
      expect(event.output_tokens).to eq(request_payload[:max_tokens])
      expect(event.input_tokens).to be > 0
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

    it "returns a buffered 502 when the upstream connection fails before the stream starts" do
      stub_request(:post, messages_url).to_raise(HTTP::ConnectionError)

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("api_error")
    end

    it "renders an upstream rejection as a buffered error instead of a stream" do
      stub_request(:post, messages_url)
        .to_return(status: 401, body: { type: "error", error: { type: "authentication_error", message: "bad key" } }.to_json)

      post_messages(request_payload.merge(stream: true))

      expect(response.status).to eq(401)
      expect(response.body).to include("bad key")
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

    it "shares the concurrent in-flight limit" do
      $redis.set(RedisKey.gumhead_gateway_in_flight(@user.id), described_class::MAX_IN_FLIGHT_REQUESTS)

      post :count_tokens, body: request_payload.to_json, as: :json

      expect(response.status).to eq(429)
      expect(WebMock).not_to have_requested(:post, count_tokens_url)
    end
  end
end
