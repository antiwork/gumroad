# frozen_string_literal: true

require "spec_helper"

describe "Muse MCP" do
  include Devise::Test::IntegrationHelpers

  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @seller = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @seller, name: "Field notes", price_cents: 1900)
  end

  def post_mcp(payload, token: @token)
    headers = {
      "CONTENT_TYPE" => "application/json",
      "HOST" => DOMAIN,
      "ACCEPT" => "application/json, text/event-stream"
    }
    headers["Authorization"] = "Bearer #{token.token}" if token
    post "/muse/v1/mcp", params: payload.to_json, headers:
  end

  # Per-form CSRF tokens: the approve and deny forms each carry their own.
  def authenticity_token(doc, method: "post")
    form = doc.css("form").find do |candidate|
      (candidate.at_css("input[name='_method']")&.[]("value") || "post") == method
    end
    form.at_css("input[name='authenticity_token']")["value"]
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end

  it "exposes a public status endpoint" do
    get "/muse/v1/status", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    expect(response.parsed_body).to eq("status" => "success")
  end

  it "advertises the MCP endpoint and OAuth" do
    get "/.well-known/mcp.json", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    body = response.parsed_body
    expect(body["name"]).to eq("Gumroad")
    expect(body["mcp"]).to eq("#{PROTOCOL}://#{DOMAIN}/muse/v1/mcp")
    expect(body["oauth"]["authorization_endpoint"]).to eq("#{PROTOCOL}://#{DOMAIN}/muse/v1/oauth2/authorize")
    expect(body["oauth"]["registration_endpoint"]).to eq("#{PROTOCOL}://#{DOMAIN}/muse/v1/oauth2/register")
    expect(body["oauth"]["scopes"]).to include("view_sales", "edit_products")
    expect(body["clients"]).to include(
      "muse" => "#{PROTOCOL}://#{DOMAIN}/muse/v1/mcp",
      "claude" => "#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp",
      "chatgpt" => "#{PROTOCOL}://#{DOMAIN}/chatgpt/v1/mcp"
    )
  end

  it "returns OAuth protected resource metadata" do
    get "/.well-known/oauth-protected-resource", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    expect(response.parsed_body["resource"]).to eq("#{PROTOCOL}://#{DOMAIN}/muse/v1/mcp")
    expect(response.parsed_body["authorization_servers"]).to eq(["#{PROTOCOL}://#{DOMAIN}"])

    get "/.well-known/oauth-protected-resource/claude/v1/mcp", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    expect(response.parsed_body["resource"]).to eq("#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp")
  end

  it "registers a public OAuth client for MCP" do
    expect do
      post "/claude/v1/oauth2/register",
           params: {
             client_name: "Claude",
             redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
             token_endpoint_auth_method: "none"
           }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
    end.to change(OauthApplication, :count).by(1)

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body["client_id"]).to be_present
    expect(body).not_to have_key("client_secret")
    application = OauthApplication.find_by!(uid: body["client_id"])
    expect(application).not_to be_confidential
    expect(application.owner).to be_nil
    expect(application).to be_mcp_dynamic_client
    expect(@app).not_to be_mcp_dynamic_client
  end

  %w[none client_secret_post client_secret_basic].each do |method|
    it "registers the supported #{method} authentication method" do
      post "/muse/v1/oauth2/register",
           params: { redirect_uris: ["https://example.com/callback"], token_endpoint_auth_method: method }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["token_endpoint_auth_method"]).to eq(method)
      application = OauthApplication.find_by!(uid: body["client_id"])
      expect(application.confidential?).to eq(method != "none")
      expect(body.key?("client_secret")).to eq(method != "none")
    end
  end

  %w[private_key_jwt client_secret_jwt tls_client_auth unknown].each do |method|
    it "rejects unsupported #{method} authentication without creating a client" do
      expect do
        post "/chatgpt/v1/oauth2/register",
             params: { redirect_uris: ["https://example.com/callback"], token_endpoint_auth_method: method }.to_json,
             headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
      end.not_to change(OauthApplication, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include(
        "error" => "invalid_client_metadata",
        "error_description" => "unsupported token_endpoint_auth_method"
      )
    end
  end

  it "rejects a non-https redirect URI during registration" do
    expect do
      post "/chatgpt/v1/oauth2/register",
           params: { redirect_uris: ["http://evil.example"] }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
    end.not_to change(OauthApplication, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("invalid_client_metadata")
  end

  it "stores the real Claude and ChatGPT callbacks without truncation" do
    redirect_uris = %w[https://claude.ai/api/mcp/auth_callback https://chatgpt.com/connector_platform_oauth_redirect]

    post "/muse/v1/oauth2/register",
         params: { redirect_uris:, token_endpoint_auth_method: "none" }.to_json,
         headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:created)
    expect(response.parsed_body["redirect_uris"]).to eq(redirect_uris)
    expect(OauthApplication.find_by!(uid: response.parsed_body["client_id"]).redirect_uri).to eq(redirect_uris.join("\n"))
  end

  it "rejects more redirect URIs than a registration may hold without creating a client" do
    redirect_uris = (1..(Muse::OauthClientRegistration::REDIRECT_URIS_MAX + 1)).map { |i| "https://example.com/callback/#{i}" }

    expect do
      post "/claude/v1/oauth2/register",
           params: { redirect_uris: }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
    end.not_to change(OauthApplication, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq(
      "error" => "invalid_client_metadata",
      "error_description" => "redirect_uris must contain at most #{Muse::OauthClientRegistration::REDIRECT_URIS_MAX} entries"
    )
  end

  it "rejects redirect URIs the stored allowlist column would truncate without creating a client" do
    redirect_uris = ["https://example.com/#{"a" * 200}", "https://example.org/#{"b" * 60}"]
    limit = Muse::OauthClientRegistration::REDIRECT_URIS_MAX_LENGTH
    expect(redirect_uris.map(&:length).max).to be <= limit
    expect(redirect_uris.join("\n").length).to be > limit

    expect do
      post "/chatgpt/v1/oauth2/register",
           params: { redirect_uris: }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
    end.not_to change(OauthApplication, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq(
      "error" => "invalid_client_metadata",
      "error_description" => "redirect_uris must be at most #{limit} characters combined"
    )
  end

  it "returns RFC 8414 metadata" do
    get "/.well-known/oauth-authorization-server", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    body = response.parsed_body
    expect(body["issuer"]).to eq("#{PROTOCOL}://#{DOMAIN}")
    expect(body["authorization_endpoint"]).to end_with("/muse/v1/oauth2/authorize")
    expect(body["token_endpoint"]).to end_with("/muse/v1/oauth2/token")
    expect(body["code_challenge_methods_supported"]).to include("S256")
    expect(body["registration_endpoint"]).to end_with("/muse/v1/oauth2/register")
    expect(body["token_endpoint_auth_methods_supported"]).to include("none")
  end

  it "returns 401 without a token" do
    post_mcp({ jsonrpc: "2.0", id: 1, method: "ping" }, token: nil)

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to include("resource_metadata=\"#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/muse/v1/mcp\"")
  end

  it "points Claude and ChatGPT 401 challenges at their own resource metadata" do
    %w[claude chatgpt].each do |client|
      post "/#{client}/v1/mcp",
           params: { jsonrpc: "2.0", id: 1, method: "ping" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include(
        "resource_metadata=\"#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/#{client}/v1/mcp\""
      )
    end
  end

  it "serves the same MCP tools on Claude and ChatGPT aliases" do
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    headers = { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{token.token}" }

    %w[claude chatgpt].each do |client|
      post "/#{client}/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: headers

      expect(response).to be_successful
      names = response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }
      expect(names).to include("list_sales", "create_draft_product")
    end
  end

  context "with a view_sales token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    end

    it "lists tools" do
      post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" })

      expect(response).to be_successful
      names = response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }
      expect(names).to include("get_account", "list_products", "list_sales", "create_draft_product", "publish_product")
    end

    it "lists sales" do
      purchase = create(:purchase, seller: @seller, link: @product, email: "buyer@example.com", price_cents: 1900)

      post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_sales", arguments: {} } })

      expect(response).to be_successful
      sales = response.parsed_body.dig("result", "structuredContent", "sales")
      expect(sales.map { |sale| sale["id"] }).to include(purchase.external_id)
      listed = sales.find { |sale| sale["id"] == purchase.external_id }
      expect(listed["email"]).to eq("buyer@example.com")
      expect(listed["refunded"]).to eq(false)
    end

    it "refuses a write tool" do
      expect { post_mcp({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } }) }.not_to change(Link, :count)

      expect(response.parsed_body.dig("error", "message")).to include("edit_products")
    end
  end

  context "with an edit_products token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "edit_products")
    end

    it "creates a draft and does not publish it" do
      post_mcp({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Muse draft", price_cents: 1900, description: "A note." } } })

      expect(response).to be_successful
      payload = response.parsed_body.dig("result", "structuredContent", "product")
      expect(payload["name"]).to eq("Muse draft")
      expect(payload["published"]).to eq(false)
      product = @seller.links.find_by_external_id(payload["id"])
      expect(product).to be_draft
      expect(product.purchase_disabled_at).to be_present
    end

    it "publishes an existing product the seller owns" do
      @product.update!(draft: true, purchase_disabled_at: Time.current)

      post_mcp({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "publish_product", arguments: { id: @product.external_id } } })

      expect(response).to be_successful
      expect(response.parsed_body.dig("result", "structuredContent", "product", "published")).to eq(true)
      expect(@product.reload).to be_published
    end
  end

  context "with a default-scope (view_public) token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_public")
    end

    it "lists tools and reads products" do
      post_mcp({ jsonrpc: "2.0", id: 6, method: "tools/list" })
      expect(response).to be_successful

      post_mcp({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "list_products", arguments: {} } })
      expect(response).to be_successful
      names = response.parsed_body.dig("result", "structuredContent", "products").map { |product| product["name"] }
      expect(names).to include("Field notes")
    end

    it "refuses a write tool" do
      expect { post_mcp({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } }) }.not_to change(Link, :count)

      expect(response.parsed_body.dig("error", "message")).to include("edit_products")
    end
  end

  context "with a view_sales token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    end

    it "answers nothing to a notification" do
      post_mcp({ jsonrpc: "2.0", method: "notifications/initialized" })

      expect(response).to have_http_status(:accepted)

      post_mcp({ jsonrpc: "2.0", method: "tools/list" })

      expect(response).to have_http_status(:accepted)
    end

    %w[muse claude chatgpt].each do |client|
      [0, "missing-method"].each do |id|
        it "returns a correlated method error over HTTP 200 on #{client} for ID #{id.inspect}" do
          post "/#{client}/v1/mcp",
               params: { jsonrpc: "2.0", id:, method: "resources/list" }.to_json,
               headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json",
                          "ACCEPT" => "application/json, text/event-stream", "Authorization" => "Bearer #{@token.token}" }

          expect(response).to have_http_status(:ok)
          expect(response.media_type).to eq("application/json")
          expect(response.parsed_body).to include("jsonrpc" => "2.0", "id" => id, "error" => include("code" => -32601))
        end
      end
    end

    it "reports invalid params rather than crashing" do
      post_mcp({ jsonrpc: "2.0", id: 9, method: "tools/call", params: [] })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("error", "code")).to eq(-32602)

      post_mcp({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "list_sales", arguments: [] } })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("error", "code")).to eq(-32602)

      post_mcp({ jsonrpc: "2.0", id: 11, method: "tools/call", params: { name: "list_sales", arguments: { limit: true } } })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("error", "code")).to eq(-32602)
    end
  end

  context "protocol and tool regressions" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "account")
    end

    def tool_call(name, arguments = {})
      { jsonrpc: "2.0", id: "tool", method: "tools/call", params: { name:, arguments: } }
    end

    it "labels persisted non-USD sales with the currency of their stored USD amount" do
      @product.update!(price_currency_type: Currency::EUR, price_cents: 1000)
      purchase = create(:purchase, seller: @seller, link: @product, price_cents: 1200,
                                   displayed_price_cents: 1000, displayed_price_currency_type: Currency::EUR,
                                   rate_converted_to_usd: "1.2")

      post_mcp(tool_call("list_sales"))

      sale = response.parsed_body.dig("result", "structuredContent", "sales").sole
      expect(purchase.reload.price_cents).to eq(1200)
      expect(purchase.displayed_price_cents).to eq(1000)
      expect(sale).to include("price_cents" => 1200, "currency" => Currency::USD)
    end

    it "rejects GET with a write body without changing the product" do
      body = tool_call("unpublish_product", { id: @product.external_id }).to_json

      expect do
        get "/muse/v1/mcp", headers: { "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}",
                                       "ACCEPT" => "text/event-stream", "CONTENT_TYPE" => "application/json" },
                            env: { "rack.input" => StringIO.new(body), "CONTENT_LENGTH" => body.bytesize.to_s }
      end.not_to change { @product.reload.attributes }

      expect(response).to have_http_status(:method_not_allowed)
      expect(response.headers["Allow"]).to eq("POST")
      expect(response.body).to be_empty
    end

    it "rejects GET without a body instead of offering an SSE stream" do
      get "/muse/v1/mcp", headers: { "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}", "ACCEPT" => "text/event-stream" }

      expect(response).to have_http_status(:method_not_allowed)
      expect(response.headers["Allow"]).to eq("POST")
    end

    it "responds to each request in a batch using its original ID" do
      post_mcp([{ jsonrpc: "2.0", id: 0, method: "ping" }, { jsonrpc: "2.0", id: "init", method: "initialize" }])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.first).to eq("jsonrpc" => "2.0", "id" => 0, "result" => {})
      expect(response.parsed_body.last.dig("result", "protocolVersion")).to eq("2025-03-26")
      expect(response.parsed_body.last["id"]).to eq("init")
    end

    it "omits notifications from mixed batch results and isolates invalid elements" do
      post_mcp([
                 { jsonrpc: "2.0", method: "notifications/initialized" },
                 { jsonrpc: "2.0", id: "ok", method: "ping" },
                 tool_call("unknown_tool"),
                 12, [], {},
                 { jsonrpc: "2.0", method: "unknown_notification" }
               ])

      expect(response).to have_http_status(:ok)
      results = response.parsed_body
      expect(results.size).to eq(5)
      expect(results[0]).to include("id" => "ok", "result" => {})
      expect(results[1]).to include("id" => "tool", "error" => include("code" => -32602))
      expect(results.drop(2)).to all(include("id" => nil, "error" => include("code" => -32600)))
    end

    it "executes a valid batch write even when another element is invalid" do
      expect do
        post_mcp([{}, tool_call("create_draft_product", { name: "Batch draft", price_cents: 500 })])
      end.to change(@seller.links, :count).by(1)

      expect(response.parsed_body.first.dig("error", "code")).to eq(-32600)
      expect(@seller.links.order(:id).last).to be_draft
      expect(response.parsed_body.last.dig("result", "structuredContent", "product", "published")).to eq(false)
    end

    it "accepts notification-only batches without a response body" do
      post_mcp([{ jsonrpc: "2.0", method: "notifications/initialized" }, { jsonrpc: "2.0", method: "ping" }])

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    it "does not reply to a rejected write notification or create a product" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "Invalid price", price_cents: -0.9 }).except(:id))
      end.not_to change(Link, :count)

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    it "does not reply to a notification whose tool fails a model guard" do
      @seller.update!(confirmed_at: nil)
      @product.update!(draft: true, purchase_disabled_at: Time.current)

      expect do
        post_mcp(tool_call("publish_product", { id: @product.external_id }).except(:id))
      end.not_to change { @product.reload.attributes }

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    ["ping", "tools/list", "unknown_notification"].each do |method|
      it "does not reply to a valid #{method} notification" do
        post_mcp({ jsonrpc: "2.0", method: })

        expect(response).to have_http_status(:accepted)
        expect(response.body).to be_empty
      end
    end

    [[], {}, nil, true, 42, "ping"].each do |body|
      it "reports #{body.inspect} as an invalid request rather than a parse error or notification" do
        post_mcp(body)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => nil, "error" => include("code" => -32600))
      end
    end

    it "reports invalid JSON as a parse error" do
      post "/muse/v1/mcp", params: "{", headers: { "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}", "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("id" => nil, "error" => include("code" => -32700))
    end

    [nil, true, {}, [], 1.5].each do |id|
      it "rejects a write with invalid MCP ID #{id.inspect} before creating a product" do
        expect do
          post_mcp(tool_call("create_draft_product", { name: "Invalid envelope", price_cents: 500 }).merge(id:))
        end.not_to change(Link, :count)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => nil, "error" => include("code" => -32600))
      end
    end

    [{ jsonrpc: nil }, { jsonrpc: "1.0" }, { method: nil }, { method: 12 }, { result: {} }, { error: { code: -1, message: "no" } }].each do |invalid|
      it "rejects a write envelope containing #{invalid.inspect} without changing the product" do
        expect do
          post_mcp(tool_call("unpublish_product", { id: @product.external_id }).merge(invalid))
        end.not_to change { @product.reload.attributes }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => "tool", "error" => include("code" => -32600))
      end
    end

    it "rejects a write without a JSON-RPC version" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "No version", price_cents: 500 }).except(:jsonrpc))
      end.not_to change(Link, :count)

      expect(response.parsed_body).to include("id" => "tool", "error" => include("code" => -32600))
    end

    [{ result: {} }, { error: { code: -32601, message: "Unknown method" } }].each do |reply|
      it "accepts an unsolicited client #{reply.keys.first} without dispatching or replying" do
        expect { post_mcp({ jsonrpc: "2.0", id: "client" }.merge(reply)) }.not_to change(Link, :count)

        expect(response).to have_http_status(:accepted)
        expect(response.body).to be_empty
      end
    end

    it "accepts a batch of well-formed client responses without replying" do
      post_mcp([{ jsonrpc: "2.0", id: 1, result: {} }, { jsonrpc: "2.0", id: 2, error: { code: -32601, message: "Unknown" } }])

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    [{ result: {}, error: { code: -1, message: "No" } }, { result: [] }, { error: { code: "bad", message: "No" } }].each do |reply|
      it "rejects malformed client response #{reply.inspect}" do
        post_mcp({ jsonrpc: "2.0", id: "client" }.merge(reply))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => "client", "error" => include("code" => -32600))
      end
    end

    [-0.9, 1900.9, -1, "500", true, nil].each do |price_cents|
      it "rejects price #{price_cents.inspect} without creating or publishing a product" do
        expect do
          post_mcp(tool_call("create_draft_product", { name: "Invalid price", price_cents: }))
        end.not_to change(Link, :count)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("id" => "tool", "error" => include("code" => -32602))
      end
    end

    it "allows an integer zero price and keeps the new product unpublished" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "Free draft", price_cents: 0 }))
      end.to change(@seller.links, :count).by(1)

      product = @seller.links.find_by_external_id(response.parsed_body.dig("result", "structuredContent", "product", "id"))
      expect(product.price_cents).to eq(0)
      expect(product).to be_draft
      expect(product).not_to be_published
    end

    [1.5, "2", false, nil, [], 0, 51].each do |limit|
      it "rejects malformed limit #{limit.inspect}" do
        post_mcp(tool_call("list_products", { limit: }))

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("id" => "tool", "error" => include("code" => -32602))
      end
    end

    it "reports product validation failures as tool errors without persisting a product" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "a" * 256, price_cents: 500 }))
      end.not_to change(Link, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("error")
      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content")).to include(include("type" => "text", "text" => include("Name")))
    end

    it "reports a publish guard as a tool error and leaves the draft unchanged" do
      @seller.update!(confirmed_at: nil)
      @product.update!(draft: true, purchase_disabled_at: Time.current)

      expect { post_mcp(tool_call("publish_product", { id: @product.external_id })) }.not_to change { @product.reload.attributes }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("error")
      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content")).to include(include("type" => "text", "text" => include("confirm your email")))
    end

    %w[publish_product unpublish_product].each do |tool|
      it "refuses #{tool} for another seller without modifying either seller's product" do
        other_product = create(:product, draft: true, purchase_disabled_at: Time.current)

        expect do
          post_mcp(tool_call(tool, { id: other_product.external_id }))
        end.not_to change { [@product.reload.attributes, other_product.reload.attributes] }

        expect(response.parsed_body.dig("result", "isError")).to eq(true)
        expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
      end

      it "refuses #{tool} without a write scope and leaves the product unchanged" do
        @token.update!(scopes: "view_public")
        @product.update!(draft: true, purchase_disabled_at: Time.current) if tool == "publish_product"

        expect { post_mcp(tool_call(tool, { id: @product.external_id })) }.not_to change { @product.reload.attributes }

        expect(response.parsed_body.dig("error", "message")).to include("edit_products")
      end
    end
  end

  context "with a dynamically registered public client" do
    let(:redirect_uri) { "https://claude.ai/api/mcp/auth_callback" }
    let(:claude_resource) { "#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp" }
    let(:code_verifier) { SecureRandom.urlsafe_base64(48) }
    let(:code_challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false) }
    let(:ping) { { jsonrpc: "2.0", id: 1, method: "ping" } }

    before do
      host! DOMAIN
      stub_vite_layout_helpers

      post "/claude/v1/oauth2/register",
           params: { client_name: "Claude", redirect_uris: [redirect_uri], token_endpoint_auth_method: "none", scope: "view_sales" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      @client_id = response.parsed_body.fetch("client_id")
      @application = OauthApplication.find_by!(uid: @client_id)

      sign_in @seller
    end

    it "renders consent for the ownerless client and carries the S256 challenge and resource into the form" do
      doc = consent_page

      expect(response).to have_http_status(:ok)
      expect(@application.owner).to be_nil
      expect(response.body).to include("MCP Claude")
      expect(doc.at_css("input[name='code_challenge']")["value"]).to eq(code_challenge)
      expect(doc.at_css("input[name='code_challenge_method']")["value"]).to eq("S256")
      expect(doc.at_css("input[name='resource']")["value"]).to eq(claude_resource)
    end

    it "requires an S256 challenge on the alias and on the canonical /oauth path without creating a grant" do
      expect do
        get "/claude/v1/oauth2/authorize", params: authorize_params.except(:code_challenge, :code_challenge_method)
        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include("code_challenge with code_challenge_method S256 is required")

        get "/oauth/authorize", params: authorize_params(code_challenge: code_verifier, code_challenge_method: "plain")
        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include("code_challenge with code_challenge_method S256 is required")

        doc = consent_page
        post "/oauth/authorize", params: authorize_params.except(:code_challenge, :code_challenge_method).merge(authenticity_token: authenticity_token(doc))
        expect(response).to have_http_status(:found)
        expect(Rack::Utils.parse_query(URI.parse(response.location).query)).to include("error" => "invalid_request", "state" => "xyz")
      end.not_to change(Doorkeeper::AccessGrant, :count)
    end

    it "requires a supported resource and rejects unknown targets without creating a grant" do
      expect do
        get "/claude/v1/oauth2/authorize", params: authorize_params.except(:resource)
        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include("resource is required")

        get "/oauth/authorize", params: authorize_params(resource: "https://evil.example/mcp")
        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include("resource is not a supported MCP resource")

        doc = consent_page
        post "/oauth/authorize", params: authorize_params(resource: "#{claude_resource}/").merge(authenticity_token: authenticity_token(doc))
        expect(response).to have_http_status(:found)
        expect(Rack::Utils.parse_query(URI.parse(response.location).query)).to include("error" => "invalid_target", "state" => "xyz")
      end.not_to change(Doorkeeper::AccessGrant, :count)
    end

    it "refuses the client_credentials grant for a dynamic client" do
      expect do
        post "/claude/v1/oauth2/token", params: { grant_type: "client_credentials", client_id: @client_id, scope: "view_sales" }
      end.not_to change(Doorkeeper::AccessToken, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("unauthorized_client")
    end

    it "leaves manually created applications on Doorkeeper's default rules and off the resource binding" do
      legacy_app = create(:oauth_application, owner: create(:user), confidential: false, redirect_uri: "https://example.com/callback", scopes: "view_sales")
      legacy_params = { response_type: "code", client_id: legacy_app.uid, redirect_uri: "https://example.com/callback", scope: "view_sales", state: "legacy", resource: "https://evil.example/mcp" }

      get "/oauth/authorize", params: legacy_params
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("input[name='resource']")).to be_nil

      post "/oauth/authorize", params: legacy_params.merge(authenticity_token: authenticity_token(doc))
      expect(response).to have_http_status(:found)
      code = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("code")
      expect(legacy_app.access_grants.last.resource).to be_nil

      post "/oauth/token", params: { grant_type: "authorization_code", code:, redirect_uri: "https://example.com/callback", client_id: legacy_app.uid }
      expect(response).to have_http_status(:ok)
      legacy_token = response.parsed_body.fetch("access_token")
      expect(Doorkeeper::AccessToken.by_token(legacy_token).resource).to be_nil

      mcp_call(legacy_token, ping)
      expect(response).to have_http_status(:ok)
      get "/api/v2/user", headers: { "Authorization" => "Bearer #{legacy_token}" }
      expect(response).to have_http_status(:ok)
    end

    it "refuses an unregistered redirect URI and an unregistered scope without creating a grant" do
      expect do
        get "/claude/v1/oauth2/authorize", params: authorize_params(redirect_uri: "https://evil.example/callback")
        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include("match client redirect URI.")

        get "/claude/v1/oauth2/authorize", params: authorize_params(scope: "edit_products")
        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include("The requested scope is invalid, unknown, or malformed.")
      end.not_to change(Doorkeeper::AccessGrant, :count)
    end

    it "sends a denied consent back to the client with access_denied and no grant" do
      doc = consent_page

      expect do
        delete "/oauth/authorize", params: authorize_params.merge(authenticity_token: authenticity_token(doc, method: "delete"))
      end.not_to change(Doorkeeper::AccessGrant, :count)

      expect(response).to have_http_status(:found)
      location = URI.parse(response.location)
      expect("#{location.scheme}://#{location.host}#{location.path}").to eq(redirect_uri)
      expect(Rack::Utils.parse_query(location.query)).to eq("error" => "access_denied", "error_description" => "The resource owner or authorization server denied the request.", "state" => "xyz")
    end

    it "exchanges an S256 code without a secret, binds the token to its resource, rotates on refresh, and honors revocation" do
      code = approve_consent
      grant = @application.access_grants.last
      expect(grant.code_challenge_method).to eq("S256")
      expect(grant.resource_owner_id).to eq(@seller.id)
      expect(grant.scopes.to_s).to eq("view_sales")
      expect(grant.resource).to eq(claude_resource)

      expect { exchange_code(code, "not-the-verifier") }.not_to change(Doorkeeper::AccessToken, :count)
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_grant")

      expect { exchange_code(code, code_verifier, resource: "#{PROTOCOL}://#{DOMAIN}/chatgpt/v1/mcp") }.not_to change(Doorkeeper::AccessToken, :count)
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq("error" => "invalid_target", "error_description" => "resource does not match the authorization request")

      body = exchange_code(code, code_verifier, resource: claude_resource)
      expect(response).to have_http_status(:ok)
      expect(body).to include("token_type" => "Bearer", "scope" => "view_sales")
      access_token = body.fetch("access_token")
      refresh_token = body.fetch("refresh_token")
      issued = Doorkeeper::AccessToken.by_token(access_token)
      expect(issued.application_id).to eq(@application.id)
      expect(issued.resource).to eq(claude_resource)

      expect { exchange_code(code, code_verifier) }.not_to change(Doorkeeper::AccessToken, :count)
      expect(response.parsed_body["error"]).to eq("invalid_grant")

      mcp_call(access_token, { jsonrpc: "2.0", id: 1, method: "tools/list" })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }).to include("list_sales")

      %w[chatgpt muse].each do |other|
        post "/#{other}/v1/mcp", params: ping.to_json, headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{access_token}" }
        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to include("resource_metadata=\"#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/#{other}/v1/mcp\"")
      end
      get "/api/v2/user", headers: { "Authorization" => "Bearer #{access_token}" }
      expect(response).to have_http_status(:unauthorized)

      purchase = create(:purchase, seller: @seller, link: @product, email: "buyer@example.com", price_cents: 1900)
      mcp_call(access_token, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_sales", arguments: {} } })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("result", "structuredContent", "sales").map { |sale| sale["id"] }).to include(purchase.external_id)

      expect do
        mcp_call(access_token, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } })
      end.not_to change(Link, :count)
      expect(response.parsed_body.dig("error", "message")).to include("edit_products")

      expect do
        post "/claude/v1/oauth2/token", params: { grant_type: "refresh_token", refresh_token:, client_id: @client_id, resource: "#{PROTOCOL}://#{DOMAIN}/muse/v1/mcp" }
      end.not_to change(Doorkeeper::AccessToken, :count)
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_target")
      expect(Doorkeeper::AccessToken.by_token(access_token)).not_to be_revoked

      post "/claude/v1/oauth2/token", params: { grant_type: "refresh_token", refresh_token:, client_id: @client_id, resource: claude_resource }
      expect(response).to have_http_status(:ok)
      refreshed = response.parsed_body
      expect(refreshed["scope"]).to eq("view_sales")
      expect(refreshed["access_token"]).not_to eq(access_token)
      expect(refreshed["refresh_token"]).not_to eq(refresh_token)
      expect(Doorkeeper::AccessToken.by_token(refreshed["access_token"]).resource).to eq(claude_resource)
      # oauth_access_tokens has no previous_refresh_token column, so Doorkeeper revokes the source token on refresh.
      expect(Doorkeeper::AccessToken.by_token(access_token)).to be_revoked

      mcp_call(access_token, ping)
      expect(response).to have_http_status(:unauthorized)
      mcp_call(refreshed["access_token"], ping)
      expect(response).to have_http_status(:ok)

      post "/claude/v1/oauth2/token", params: { grant_type: "refresh_token", refresh_token:, client_id: @client_id }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_grant")

      @application.revoke_access_for(@seller)

      mcp_call(refreshed["access_token"], ping)
      expect(response).to have_http_status(:unauthorized)
      post "/claude/v1/oauth2/token", params: { grant_type: "refresh_token", refresh_token: refreshed["refresh_token"], client_id: @client_id }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_grant")
    end

    def authorize_params(overrides = {})
      {
        response_type: "code",
        client_id: @client_id,
        redirect_uri:,
        scope: "view_sales",
        state: "xyz",
        code_challenge:,
        code_challenge_method: "S256",
        resource: claude_resource
      }.merge(overrides)
    end

    def consent_page
      get "/claude/v1/oauth2/authorize", params: authorize_params
      Nokogiri::HTML(response.body)
    end

    # The consent form posts to the canonical Doorkeeper path, not the connector alias.
    def approve_consent
      doc = consent_page
      expect(response).to have_http_status(:ok)

      post "/oauth/authorize", params: authorize_params.merge(authenticity_token: authenticity_token(doc))

      expect(response).to have_http_status(:found)
      location = URI.parse(response.location)
      expect("#{location.scheme}://#{location.host}#{location.path}").to eq(redirect_uri)
      query = Rack::Utils.parse_query(location.query)
      expect(query["state"]).to eq("xyz")
      query.fetch("code")
    end

    def exchange_code(code, verifier, resource: nil)
      post "/claude/v1/oauth2/token", params: { grant_type: "authorization_code", code:, redirect_uri:, client_id: @client_id, code_verifier: verifier, resource: }.compact
      response.parsed_body
    end

    def mcp_call(token, payload)
      post "/claude/v1/mcp", params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{token}" }
    end
  end

  context "with a manually created confidential client" do
    let(:redirect_uri) { "https://example.com/callback" }
    let(:legacy_app) { create(:oauth_application, owner: create(:user), confidential: true, redirect_uri:, scopes: "view_sales view_profile") }

    before do
      host! DOMAIN
      stub_vite_layout_helpers
      sign_in @seller
    end

    def authorize(scope:, client: legacy_app)
      get "/oauth/authorize", params: { response_type: "code", client_id: client.uid, redirect_uri:, scope:, state: "again" }
    end

    it "skips consent and returns straight to the client when a live token already covers the requested scopes" do
      create("doorkeeper/access_token", application: legacy_app, resource_owner_id: @seller.id, scopes: "view_sales")

      expect { authorize(scope: "view_sales") }.to change(legacy_app.access_grants, :count).by(1)

      expect(response).to have_http_status(:found)
      location = URI.parse(response.location)
      expect("#{location.scheme}://#{location.host}#{location.path}").to eq(redirect_uri)
      query = Rack::Utils.parse_query(location.query)
      expect(query["state"]).to eq("again")
      expect(query["code"]).to be_present
      expect(legacy_app.access_grants.last.resource).to be_nil
    end

    it "still asks for consent when no live token of this user covers the requested scopes" do
      create("doorkeeper/access_token", application: legacy_app, resource_owner_id: @seller.id, scopes: "view_sales")
      create("doorkeeper/access_token", application: legacy_app, resource_owner_id: create(:user).id, scopes: "view_sales view_profile")

      expect do
        authorize(scope: "view_sales view_profile")
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Authorize")
      end.not_to change(Doorkeeper::AccessGrant, :count)
    end

    it "still asks a public manual client for consent even with a matching token" do
      public_app = create(:oauth_application, owner: create(:user), confidential: false, redirect_uri:, scopes: "view_sales")
      create("doorkeeper/access_token", application: public_app, resource_owner_id: @seller.id, scopes: "view_sales")

      expect { authorize(scope: "view_sales", client: public_app) }.not_to change(Doorkeeper::AccessGrant, :count)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Authorize")
    end

    it "always asks a confidential dynamic client for consent even with a matching token" do
      claude_resource = "#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp"
      post "/claude/v1/oauth2/register",
           params: { redirect_uris: ["https://claude.ai/api/mcp/auth_callback"], token_endpoint_auth_method: "client_secret_post", scope: "view_sales" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      dynamic_app = OauthApplication.find_by!(uid: response.parsed_body.fetch("client_id"))
      expect(dynamic_app).to be_confidential
      create("doorkeeper/access_token", application: dynamic_app, resource_owner_id: @seller.id, scopes: "view_sales", resource: claude_resource)
      code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(SecureRandom.urlsafe_base64(48)), padding: false)

      expect do
        get "/claude/v1/oauth2/authorize", params: {
          response_type: "code", client_id: dynamic_app.uid, redirect_uri: "https://claude.ai/api/mcp/auth_callback", scope: "view_sales",
          state: "dcr", code_challenge:, code_challenge_method: "S256", resource: claude_resource
        }
      end.not_to change(Doorkeeper::AccessGrant, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Authorize")
      expect(Nokogiri::HTML(response.body).at_css("input[name='resource']")["value"]).to eq(claude_resource)
    end
  end
end
