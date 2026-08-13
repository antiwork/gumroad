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

    request.headers["Authorization"] = "Bearer #{@token.token}"
  end

  after { $redis.del(RedisKey.gumhead_gateway_throttle(@user.id)) }

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
      usage: { input_tokens: 50, output_tokens: 7, cache_creation_input_tokens: 3, cache_read_input_tokens: 11 },
    }
  end

  def post_messages(payload = request_payload)
    post :create, body: payload.to_json, as: :json
  end

  describe "authentication and gating" do
    it "rejects a request without a valid access token" do
      request.headers["Authorization"] = "Bearer nope"

      post_messages

      expect(response.status).to eq(401)
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

    it "throttles once the hourly request budget is spent" do
      $redis.setex(
        RedisKey.gumhead_gateway_throttle(@user.id),
        described_class::GATEWAY_REQUESTS_PERIOD_WINDOW.to_i,
        described_class::GATEWAY_REQUESTS_PER_PERIOD,
      )

      post_messages

      expect(response.status).to eq(429)
    end
  end

  describe "request validation" do
    # A malformed body posted as application/json is rejected by the JSON
    # params parser before the controller runs; this guard covers bodies
    # sent without that content type.
    it "rejects a non-JSON body" do
      post :create, body: "not json"

      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("invalid_request_error")
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
  end

  describe "streaming" do
    let(:sse_body) do
      [
        %(event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":9}}}\n\n),
        %(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}\n\n),
        %(event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":42}}\n\n),
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
      expect(event.input_tokens).to eq(50)
      expect(event.output_tokens).to eq(42)
      expect(event.cache_creation_input_tokens).to eq(2)
      expect(event.cache_read_input_tokens).to eq(9)
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
  end
end
