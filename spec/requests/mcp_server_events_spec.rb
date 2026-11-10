# frozen_string_literal: true

require "spec_helper"

describe "MCP server events" do
  let(:seller) { create(:user) }
  let(:application) { create(:oauth_application) }
  let(:scopes) { "view_sales" }
  let(:token) { create("doorkeeper/access_token", application:, resource_owner_id: seller.id, scopes:) }
  let(:callback_url) { "https://example.com/hooks/mcp" }
  let(:secret) { whsec }

  before do
    Feature.activate_user(:mcp_events, seller)
    allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"])
  end

  def whsec = "whsec_#{Base64.strict_encode64(SecureRandom.bytes(32))}"

  def rpc(method, params = nil, client: "chatgpt", modern: false)
    headers = { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{token.token}" }
    if modern
      params = (params || {}).merge(_meta: { Mcp::Server::VERSION_META_KEY => Mcp::Server::MODERN_PROTOCOL_VERSION })
      headers.merge!(Mcp::Server::VERSION_HEADER => Mcp::Server::MODERN_PROTOCOL_VERSION, Mcp::Server::METHOD_HEADER => method)
    end
    body = { jsonrpc: "2.0", id: 1, method: }
    body[:params] = params if params
    post "/#{client}/v1/mcp", params: body.to_json, headers: headers
    response.parsed_body
  end

  def subscribe(**overrides)
    rpc("events/subscribe", { name: "sale.created", arguments: {}, delivery: { mode: "webhook", url: callback_url, secret: }, cursor: nil }.merge(overrides))
  end

  # The endpoint echoes each challenge. The stub keeps every request it was sent.
  def stub_echoing_callback
    @sent = []
    stub_request(:post, callback_url).to_return(lambda do |request|
      @sent << request
      { status: 200, body: { challenge: JSON.parse(request.body)["challenge"] }.to_json }
    end)
  end

  describe "the events capability" do
    it "is advertised to ChatGPT for a seller with the flag, on both revisions" do
      Feature.activate(:mcp_protocol_2026_07_28)

      expect(rpc("initialize").dig("result", "capabilities")).to eq("tools" => { "listChanged" => false }, "events" => {})

      result = rpc("server/discover", modern: true)["result"]
      expect(result["capabilities"]).to eq("tools" => { "listChanged" => false }, "events" => {})
      expect(result["cacheScope"]).to eq("private")
    end

    it "is not advertised, and the events methods do not exist, on another connector" do
      expect(rpc("initialize", client: "claude").dig("result", "capabilities")).to eq("tools" => { "listChanged" => false })
      expect(rpc("events/list", client: "claude")["error"]).to include("code" => -32601)
    end

    it "is not advertised, and the events methods do not exist, for a seller without the flag" do
      Feature.deactivate_user(:mcp_events, seller)

      expect(rpc("initialize").dig("result", "capabilities")).to eq("tools" => { "listChanged" => false })
      expect(rpc("events/subscribe")["error"]).to include("code" => -32601)
    end
  end

  describe "events/list" do
    it "lists the sale event with its schemas, and counts the call" do
      events = rpc("events/list").dig("result", "events")

      expect(events.map { _1["name"] }).to eq(["sale.created"])
      expect(events.first).to include("delivery" => ["webhook"], "inputSchema" => { "type" => "object", "properties" => {}, "additionalProperties" => false })
      expect(events.first.dig("payloadSchema", "required")).to eq(%w[sale_id product_id product_name price_cents currency created_at])
      expect(Mcp::ProtocolTelemetry.mix["chatgpt"]).to eq("undeclared" => { "events/list" => 1 })
    end

    it "answers on the 2026-07-28 revision" do
      Feature.activate(:mcp_protocol_2026_07_28)

      result = rpc("events/list", modern: true)["result"]

      expect(result["resultType"]).to eq("complete")
      expect(result["events"].map { _1["name"] }).to eq(["sale.created"])
    end
  end

  describe "events/subscribe" do
    it "verifies a new callback URL, stores the subscription, and answers with its lease", :freeze_time do
      stub_echoing_callback

      result = subscribe["result"]

      subscription = McpEventSubscription.sole
      expect(result).to eq("id" => subscription.public_id, "refreshBefore" => 1.day.from_now.utc.iso8601, "cursor" => nil, "truncated" => false)
      expect(subscription).to have_attributes(user: seller, oauth_application_id: application.id, event_name: "sale.created", callback_url:, secret:)
      expect(@sent.map { JSON.parse(_1.body)["type"] }).to eq(["verification"])
    end

    it "refreshes under the same id without a second challenge, takes a new secret, and grants the lifetime asked for", :freeze_time do
      stub_echoing_callback
      first = subscribe["result"]
      rotated_secret = whsec

      result = subscribe(delivery: { mode: "webhook", url: callback_url, secret: rotated_secret }, ttlMs: 3_600_000)["result"]

      expect(result["id"]).to eq(first["id"])
      expect(@sent.size).to eq(1)
      expect(McpEventSubscription.sole.secret).to eq(rotated_secret)
      expect(result["refreshBefore"]).to eq(1.hour.from_now.utc.iso8601)
    end

    it "stores nothing when the token is revoked while the challenge runs" do
      stub_request(:post, callback_url).to_return(lambda do |request|
        token.revoke
        { status: 200, body: { challenge: JSON.parse(request.body)["challenge"] }.to_json }
      end)

      error = subscribe["error"]

      expect(error["message"]).to eq("Access to this account was revoked.")
      expect(McpEventSubscription.count).to eq(0)
    end

    it "refuses events/subscribe in a batch before it sends anything" do
      message = { jsonrpc: "2.0", method: "events/subscribe", params: { name: "sale.created", arguments: {}, delivery: { mode: "webhook", url: callback_url, secret: } } }

      post "/chatgpt/v1/mcp", params: [message.merge(id: 1), message.merge(id: 2)].to_json,
                              headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{token.token}" }

      expect(response.parsed_body.map { _1.dig("error", "code") }).to eq([-32600, -32600])
      expect(a_request(:post, callback_url)).not_to have_been_made
    end

    it "challenges a URL again for another connection of the same seller" do
      stub_echoing_callback
      create(:mcp_event_subscription, user: seller, callback_url:)

      subscribe

      expect(@sent.size).to eq(1)
      expect(McpEventSubscription.count).to eq(2)
    end

    it "reports a callback URL that fails the challenge, and stores nothing" do
      stub_request(:post, callback_url).to_return(status: 200, body: "ok")

      error = subscribe["error"]

      expect(error).to eq("code" => -32015, "message" => "The callback URL failed: challenge_failed", "data" => { "reason" => "challenge_failed" })
      expect(McpEventSubscription.count).to eq(0)
    end

    it "refuses invalid parameters before it sends anything" do
      {
        { name: "refund.created" } => "Unknown event: refund.created",
        { arguments: { product_id: "abc" } } => "Unknown argument: product_id",
        { arguments: "abc" } => "arguments must be an object",
        { delivery: nil } => "delivery must be an object",
        { delivery: { mode: "push", url: callback_url, secret: } } => "delivery.mode must be webhook",
        { delivery: { mode: "webhook", url: callback_url } } => "delivery.secret must be whsec_ followed by the base64 of 24 to 64 random bytes",
        { delivery: { mode: "webhook", url: "http://example.com/hooks/mcp", secret: } } => "Callback url must be an https URL",
        { delivery: { mode: "webhook", url: callback_url, secret: "not a secret" } } => "delivery.secret must be whsec_",
        { ttlMs: "1h" } => "ttlMs must be an integer or null"
      }.each do |overrides, message|
        error = subscribe(**overrides)["error"]

        expect(error["code"]).to eq(-32602)
        expect(error["message"]).to start_with(message)
      end
      expect(a_request(:post, /example\.com/)).not_to have_been_made
      expect(McpEventSubscription.count).to eq(0)
    end

    it "refuses a subscription past the connection's limit before it sends anything" do
      stub_const("McpEventSubscription::MAX_LIVE_PER_CONNECTION", 1)
      create(:mcp_event_subscription, user: seller, oauth_application: application, callback_url: "https://example.org/hooks/mcp")

      error = subscribe["error"]

      expect(error).to include("code" => -32602, "message" => a_string_including("already has 1 live event subscriptions"))
      expect(a_request(:post, callback_url)).not_to have_been_made
    end

    context "when the token cannot read sales" do
      let(:application) { create(:oauth_application, mcp_dynamic_client: true) }
      let(:scopes) { "view_public" }

      it "asks for the view_sales scope before it sends anything" do
        error = subscribe["error"]

        expect(response).to have_http_status(:forbidden)
        expect(response.headers["WWW-Authenticate"]).to include(%(error="insufficient_scope"), %(scope="view_public view_sales"))
        expect(error).to eq("code" => -32000, "message" => "Subscribing to an event requires the view_sales or account scope.")
        expect(a_request(:post, callback_url)).not_to have_been_made
      end

      it "refuses a bad callback URL first, without asking for more access" do
        error = subscribe(delivery: { mode: "webhook", url: "http://example.com/hooks/mcp", secret: })["error"]

        expect(error).to include("code" => -32602, "message" => a_string_starting_with("Callback url must be an https URL"))
        expect(response.headers["WWW-Authenticate"]).to be_nil
      end

      it "refuses a bad secret on a refresh first, without asking for more access" do
        create(:mcp_event_subscription, user: seller, oauth_application: application, callback_url:)

        error = subscribe(delivery: { mode: "webhook", url: callback_url, secret: "not a secret" })["error"]

        expect(error).to include("code" => -32602, "message" => a_string_starting_with("delivery.secret must be whsec_"))
        expect(response.headers["WWW-Authenticate"]).to be_nil
      end
    end
  end

  it "delivers a sale to the callback URL a client subscribed, signed with the client's secret" do
    stub_echoing_callback
    subscription_id = subscribe.dig("result", "id")
    purchase = create(:free_purchase, link: create(:product, user: seller, name: "Field notes"), seller:)

    PostToPingEndpointsWorker.new.perform(purchase.id, nil)
    Mcp::DeliverEventJob.drain

    delivery = @sent.last
    expect(JSON.parse(delivery.body)).to include("name" => "sale.created", "data" => a_hash_including("sale_id" => purchase.external_id, "product_name" => "Field notes"))
    expect(delivery.headers["X-Mcp-Subscription-Id"]).to eq(subscription_id)
    signed = Mcp::EventSignature.headers(secret:, message_id: delivery.headers["Webhook-Id"], body: delivery.body, timestamp: delivery.headers["Webhook-Timestamp"].to_i)
    expect(delivery.headers["Webhook-Signature"]).to eq(signed["webhook-signature"])
  end

  describe "events/unsubscribe" do
    it "deletes the subscription for the key, answers the same when there is none, and leaves other connections alone" do
      create(:mcp_event_subscription, user: seller, oauth_application: application, callback_url:)
      other_connection = create(:mcp_event_subscription, user: seller, callback_url:)
      params = { name: "sale.created", arguments: {}, delivery: { mode: "webhook", url: callback_url } }

      2.times { expect(rpc("events/unsubscribe", params)).to include("result" => {}) }

      expect(McpEventSubscription.all).to eq([other_connection])
    end
  end
end
