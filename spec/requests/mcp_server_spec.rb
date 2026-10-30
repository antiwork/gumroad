# frozen_string_literal: true

require "spec_helper"

describe "MCP server" do
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
    expect(body["oauth"]["scopes"]).to match_array(Mcp::OauthClientRegistration::MCP_SCOPES)
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
    expect(response.parsed_body["scopes_supported"]).to match_array(Mcp::OauthClientRegistration::MCP_SCOPES)

    get "/.well-known/oauth-protected-resource/claude/v1/mcp", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    expect(response.parsed_body["resource"]).to eq("#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp")
    expect(response.parsed_body["scopes_supported"]).to match_array(Mcp::OauthClientRegistration::MCP_SCOPES)
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

  it "rejects a wildcard redirect host at registration without creating a client" do
    expect do
      post "/claude/v1/oauth2/register",
           params: { redirect_uris: ["https://*.example.org/cb"] }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
    end.not_to change(OauthApplication, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq(
      "error" => "invalid_client_metadata",
      "error_description" => "redirect_uris must not contain wildcards"
    )
  end

  it "rejects a wildcard outside the host at registration without creating a client" do
    expect do
      post "/claude/v1/oauth2/register",
           params: { redirect_uris: ["https://example.org/*"] }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
    end.not_to change(OauthApplication, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error_description"]).to eq("redirect_uris must not contain wildcards")
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
    redirect_uris = (1..(Mcp::OauthClientRegistration::REDIRECT_URIS_MAX + 1)).map { |i| "https://example.com/callback/#{i}" }

    expect do
      post "/claude/v1/oauth2/register",
           params: { redirect_uris: }.to_json,
           headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json" }
    end.not_to change(OauthApplication, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq(
      "error" => "invalid_client_metadata",
      "error_description" => "redirect_uris must contain at most #{Mcp::OauthClientRegistration::REDIRECT_URIS_MAX} entries"
    )
  end

  it "rejects redirect URIs the stored allowlist column would truncate without creating a client" do
    redirect_uris = ["https://example.com/#{"a" * 200}", "https://example.org/#{"b" * 60}"]
    limit = Mcp::OauthClientRegistration::REDIRECT_URIS_MAX_LENGTH
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
    expect(body["scopes_supported"]).to match_array(Mcp::OauthClientRegistration::MCP_SCOPES)
  end

  it "issues a Claude token with every scope discovered from the MCP metadata" do
    host! DOMAIN
    stub_vite_layout_helpers
    Rails.application.reload_routes!
    sign_in @seller

    get "/.well-known/oauth-protected-resource/claude/v1/mcp"
    resource = response.parsed_body.fetch("resource")
    scopes = response.parsed_body.fetch("scopes_supported")

    get "/.well-known/oauth-authorization-server"
    metadata = response.parsed_body
    expect(metadata.fetch("scopes_supported")).to match_array(scopes)

    redirect_uri = "https://example.com/callback"
    post URI(metadata.fetch("registration_endpoint")).path,
         params: { client_name: "Claude", redirect_uris: [redirect_uri], token_endpoint_auth_method: "none", scope: scopes.join(" ") }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:created)
    client_id = response.parsed_body.fetch("client_id")
    expect(response.parsed_body.fetch("scope").split).to match_array(scopes)

    code_verifier = SecureRandom.urlsafe_base64(48)
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)
    authorization_params = {
      response_type: "code", client_id:, redirect_uri:, scope: scopes.join(" "),
      state: "discovered-scopes", code_challenge:, code_challenge_method: "S256", resource:
    }
    get URI(metadata.fetch("authorization_endpoint")).path, params: authorization_params

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("MCP Claude")
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("input[name='scope']")["value"].split).to match_array(scopes)

    post "/oauth/authorize", params: authorization_params.merge(authenticity_token: authenticity_token(doc))

    expect(response).to have_http_status(:found)
    location = URI.parse(response.location)
    expect("#{location.scheme}://#{location.host}#{location.path}").to eq(redirect_uri)
    query = Rack::Utils.parse_query(location.query)
    expect(query.fetch("state")).to eq("discovered-scopes")
    grant = OauthApplication.find_by!(uid: client_id).access_grants.last
    expect(grant.scopes.to_a).to match_array(scopes)
    expect(grant.resource).to eq(resource)

    post URI(metadata.fetch("token_endpoint")).path, params: {
      grant_type: "authorization_code", code: query.fetch("code"), redirect_uri:,
      client_id:, code_verifier:, resource:
    }

    expect(response).to have_http_status(:ok)
    token_response = response.parsed_body
    expect(token_response.fetch("scope").split).to match_array(scopes)
    issued = Doorkeeper::AccessToken.by_token(token_response.fetch("access_token"))
    expect(issued.scopes.to_a).to match_array(scopes)
    expect(issued.resource).to eq(resource)

    headers = { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{issued.token}" }
    post "/claude/v1/mcp", params: { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Six scopes", price_cents: 500 } } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["WWW-Authenticate"]).to be_nil
    expect(response.parsed_body.dig("result", "structuredContent", "product", "name")).to eq("Six scopes")

    post "/claude/v1/mcp", params: { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_payouts", arguments: {} } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["WWW-Authenticate"]).to be_nil
    expect(response.parsed_body.dig("result", "structuredContent")).to eq("payouts" => [])
  end

  it "grants a dynamic client its registered scopes when it omits scope, and steps a narrower token up" do
    host! DOMAIN
    stub_vite_layout_helpers
    Rails.application.reload_routes!
    sign_in @seller

    resource = "#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp"
    redirect_uri = "https://example.com/callback"
    post "/claude/v1/oauth2/register",
         params: { client_name: "Muse", redirect_uris: [redirect_uri], token_endpoint_auth_method: "none" }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:created)
    client_id = response.parsed_body.fetch("client_id")
    expect(response.parsed_body.fetch("scope").split).to match_array(Mcp::OauthClientRegistration::MCP_SCOPES)

    authorize = lambda do |scope|
      code_verifier = SecureRandom.urlsafe_base64(48)
      code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)
      params = { response_type: "code", client_id:, redirect_uri:, state: "step-up", code_challenge:, code_challenge_method: "S256", resource:, scope: }.compact
      get "/claude/v1/oauth2/authorize", params: params
      expect(response).to have_http_status(:ok)
      post "/oauth/authorize", params: params.merge(authenticity_token: authenticity_token(Nokogiri::HTML(response.body)))
      expect(response).to have_http_status(:found)
      code = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("code")
      post "/claude/v1/oauth2/token", params: { grant_type: "authorization_code", code:, redirect_uri:, client_id:, code_verifier:, resource: }
      expect(response).to have_http_status(:ok)
      response.parsed_body
    end
    call_tool = lambda do |access_token, name|
      headers = { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{access_token}" }
      arguments = name == "create_draft_product" ? { name: "Stepped up", price_cents: 500 } : {}
      post "/claude/v1/mcp", params: { jsonrpc: "2.0", id: name, method: "tools/call", params: { name:, arguments: } }.to_json, headers: headers
    end

    # Omitting scope would leave the client on Doorkeeper's default (view_public only); a dynamic
    # client gets everything it registered instead.
    full_token = authorize.call(nil)
    expect(full_token.fetch("scope").split).to match_array(Mcp::OauthClientRegistration::MCP_SCOPES)
    expect { call_tool.call(full_token.fetch("access_token"), "create_draft_product") }.to change(Link, :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.headers["WWW-Authenticate"]).to be_nil

    narrow_token = authorize.call("view_public view_sales")
    expect(narrow_token.fetch("scope").split).to match_array(%w[view_public view_sales])

    expect { call_tool.call(narrow_token.fetch("access_token"), "create_draft_product") }.not_to change(Link, :count)
    expect(response).to have_http_status(:forbidden)
    expect(response.headers["WWW-Authenticate"]).to eq(
      %(Bearer realm="Gumroad", error="insufficient_scope", scope="view_public view_sales edit_products", ) +
      %(resource_metadata="#{resource.sub('/claude/v1/mcp', '/.well-known/oauth-protected-resource/claude/v1/mcp')}", ) +
      %(error_description="This tool requires the edit_products or account scope.")
    )
    expect(response.parsed_body["error"]).to eq("code" => -32000, "message" => "This tool requires the edit_products or account scope.")

    # The client re-authorizes with the scope the challenge named and keeps what it had.
    stepped_up = authorize.call("view_public view_sales edit_products")
    expect(stepped_up.fetch("scope").split).to match_array(%w[view_public view_sales edit_products])

    expect { call_tool.call(stepped_up.fetch("access_token"), "create_draft_product") }.to change(Link, :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.headers["WWW-Authenticate"]).to be_nil

    call_tool.call(stepped_up.fetch("access_token"), "list_payouts")
    expect(response).to have_http_status(:forbidden)
    expect(response.headers["WWW-Authenticate"]).to include(%(error="insufficient_scope", scope="view_public view_sales edit_products view_payouts"))
  end

  it "keeps Doorkeeper's default scope for a manually created application that omits scope" do
    host! DOMAIN
    stub_vite_layout_helpers
    Rails.application.reload_routes!
    sign_in @seller

    redirect_uri = "https://example.com/callback"
    legacy_app = create(:oauth_application, owner: create(:user), confidential: false, redirect_uri:, scopes: "view_public view_sales")
    params = { response_type: "code", client_id: legacy_app.uid, redirect_uri:, state: "legacy-default" }

    get "/oauth/authorize", params: params
    expect(response).to have_http_status(:ok)
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("input[name='scope']")["value"]).to eq("view_public")

    post "/oauth/authorize", params: params.merge(authenticity_token: authenticity_token(doc))
    expect(response).to have_http_status(:found)
    expect(legacy_app.access_grants.last.scopes.to_a).to eq(["view_public"])
  end

  it "returns 401 without a token and names every MCP scope in the challenge" do
    post_mcp({ jsonrpc: "2.0", id: 1, method: "ping" }, token: nil)

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to eq(
      %(Bearer realm="Gumroad", scope="view_public view_profile view_sales edit_products view_payouts account", ) +
      %(resource_metadata="#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/muse/v1/mcp")
    )
  end

  context "when the token owner closes their account" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    end

    it "returns 401 after the closure revokes the token" do
      expect(@seller.deactivate!).to eq(true)

      post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" })

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include("resource_metadata=\"#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/muse/v1/mcp\"")
    end

    it "returns 401 for a token that is still unrevoked" do
      @seller.update!(deleted_at: Time.current)

      post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" })

      expect(response).to have_http_status(:unauthorized)
      expect(@token.reload).not_to be_revoked
    end
  end

  it "points Claude and ChatGPT 401 challenges at their own resource metadata" do
    %w[muse claude chatgpt].each do |client|
      post "/#{client}/v1/mcp",
           params: { jsonrpc: "2.0", id: 1, method: "ping" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include(
        "resource_metadata=\"#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/#{client}/v1/mcp\""
      )
    end
  end

  it "serves tools with display titles on every MCP endpoint" do
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    headers = { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{token.token}" }

    %w[claude chatgpt].each do |client|
      post "/#{client}/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: headers

      expect(response).to be_successful
      titles = response.parsed_body.dig("result", "tools").to_h { |tool| [tool["name"], tool["title"]] }
      expect(titles).to eq(
        "get_account" => "Get account",
        "list_products" => "List products",
        "get_product" => "Get product",
        "create_draft_product" => "Create draft product",
        "update_product" => "Update product",
        "add_cover" => "Add cover",
        "list_files" => "List files",
        "add_file" => "Add file",
        "publish_product" => "Publish product",
        "unpublish_product" => "Unpublish product",
        "list_sales" => "List sales",
        "get_analytics" => "Get analytics",
        "get_sales_totals" => "Get sales totals",
        "list_payouts" => "List payouts",
        "create_bundle" => "Create bundle",
        "update_bundle" => "Update bundle",
        "create_discount_code" => "Create discount code",
        "update_discount_code" => "Update discount code",
        "expire_discount_code" => "Expire discount code"
      )
    end
  end

  describe "MCP Origin validation" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "edit_products")
    end

    %w[muse claude chatgpt].each do |client|
      it "rejects untrusted origins before writing through #{client}" do
        ["https://untrusted.example", "null", "", "#{PROTOCOL}://#{DOMAIN}.example"].each do |origin|
          expect do
            post "/#{client}/v1/mcp",
                 params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Field notes", price_cents: 1900 } } }.to_json,
                 headers: { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{@token.token}", "Origin" => origin }
          end.not_to change(Link, :count)
          expect(response).to have_http_status(:forbidden)
        end
      end

      it "rejects an untrusted GET origin on #{client}" do
        get "/#{client}/v1/mcp", headers: { "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}", "Origin" => "https://untrusted.example" }
        expect(response).to have_http_status(:forbidden)
      end

      it "accepts the canonical origin and absent origins on #{client}" do
        [nil, "#{PROTOCOL}://#{DOMAIN}"].each do |origin|
          headers = { "HOST" => DOMAIN, "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{@token.token}" }
          headers["Origin"] = origin unless origin.nil?
          post "/#{client}/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "ping" }.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to eq("jsonrpc" => "2.0", "id" => 1, "result" => {})
        end
      end
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

    it "labels reads, drafts, edits, and sale-state changes for the host" do
      post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" })

      annotations = response.parsed_body.dig("result", "tools").to_h { |tool| [tool["name"], tool["annotations"]] }
      expect(annotations.keys).to contain_exactly(
        "get_account", "list_products", "get_product", "create_draft_product", "update_product", "add_cover",
        "list_files", "add_file", "publish_product", "unpublish_product", "list_sales", "get_analytics", "get_sales_totals", "list_payouts",
        "create_bundle", "update_bundle", "create_discount_code", "update_discount_code", "expire_discount_code"
      )
      # Every tool reaches the storefront, an external publicly reachable system.
      expect(annotations.values).to all(include("openWorldHint" => true))
      %w[get_account list_products get_product list_files list_sales get_analytics get_sales_totals list_payouts].each do |name|
        expect(annotations[name]).to include("readOnlyHint" => true, "destructiveHint" => false)
      end
      %w[create_draft_product add_cover add_file create_discount_code].each do |name|
        expect(annotations[name]).to include("readOnlyHint" => false, "destructiveHint" => false)
      end
      %w[update_product publish_product unpublish_product update_bundle update_discount_code expire_discount_code].each do |name|
        expect(annotations[name]).to include("readOnlyHint" => false, "destructiveHint" => true)
      end
    end

    it "says checkout stays on the product URL" do
      post_mcp({ jsonrpc: "2.0", id: 1, method: "initialize" })

      instructions = response.parsed_body.dig("result", "instructions")
      expect(instructions).to include("check out on the product URL")
      expect(instructions).to include("does not take payment")
      expect(instructions).not_to include("Muse's browser")
      expect(instructions).not_to include("refunding")
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

    describe "get_analytics" do
      let(:permalink) { @product.unique_permalink }

      def get_analytics(arguments = {})
        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_analytics", arguments: } })
        response.parsed_body["result"]
      end

      before do
        @seller.update_columns(created_at: 2.years.ago)
        allow_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:data_for_dates)
      end

      it "returns no rows, without reading another day, for ranges before the account existed or in the future" do
        expect_any_instance_of(CreatorAnalytics::CachingProxy).not_to receive(:data_for_dates)

        [{ "start_date" => "2020-01-01", "end_date" => "2020-01-31" }, { "start_date" => 2.days.from_now.to_date.iso8601, "end_date" => 3.days.from_now.to_date.iso8601 }].each do |arguments|
          expect(get_analytics(arguments)["structuredContent"]["rows"]).to eq([])
        end
      end

      it "returns views, sales, revenue and conversion per product" do
        allow_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:data_for_dates).and_return(by_date: { views: { permalink => [10, 30] }, sales: { permalink => [1, 3] }, totals: { permalink => [1900, 5700] } })

        result = get_analytics("start_date" => "2026-10-01", "end_date" => "2026-10-02")["structuredContent"]
        expect(result["rows"]).to eq([{ "product_id" => @product.external_id, "product_name" => "Field notes", "views" => 40, "sales" => 4, "revenue_cents" => 7600, "conversion_rate" => 0.1 }])
      end

      it "sums referrers across products and filters to one product" do
        other = create(:product, user: @seller)
        by_referral = {
          views: { permalink => { "direct" => [5, 5], "Twitter" => [2, 0] }, other.unique_permalink => { "direct" => [90, 0] } },
          sales: { permalink => { "direct" => [1, 0] } },
          totals: { permalink => { "direct" => [1900, 0] } }
        }
        allow_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:data_for_dates).and_return(by_referral:)

        rows = get_analytics("breakdown" => "referrer", "product_id" => @product.external_id)["structuredContent"]["rows"]
        expect(rows).to eq([
                             { "referrer" => "direct", "views" => 10, "sales" => 1, "revenue_cents" => 1900, "conversion_rate" => 0.1 },
                             { "referrer" => "Twitter", "views" => 2, "sales" => 0, "revenue_cents" => 0, "conversion_rate" => 0.0 }
                           ])
      end

      it "returns a null conversion rate when there were no views" do
        allow_any_instance_of(CreatorAnalytics::CachingProxy).to receive(:data_for_dates).and_return(by_date: { views: { permalink => [0] }, sales: { permalink => [0] }, totals: { permalink => [0] } })

        expect(get_analytics["structuredContent"]["rows"].first["conversion_rate"]).to be_nil
      end

      it "rejects bad dates, inverted ranges and ranges over a year" do
        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_analytics", arguments: { "start_date" => "yesterday" } } })
        expect(response.parsed_body.dig("error", "message")).to eq("start_date must be a date like 2026-10-31")

        [{ "start_date" => "2026-10-05", "end_date" => "2026-10-01" }, { "start_date" => "2024-01-01", "end_date" => "2026-01-01" }].each do |arguments|
          post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_analytics", arguments: } })
          expect(response.parsed_body["error"]["code"]).to eq(-32602)
        end
      end

      it "requires the view_sales scope" do
        @token.update!(scopes: "view_profile")

        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_analytics", arguments: {} } })

        expect(response.parsed_body.to_s).to include("view_sales")
      end
    end

    describe "get_sales_totals" do
      def get_sales_totals(arguments = {})
        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_sales_totals", arguments: } })
        response.parsed_body["result"]["structuredContent"]
      end

      before { @seller.update!(timezone: "Eastern Time (US & Canada)") }

      it "returns revenue, units and average order value per product, counting only sales that still stand" do
        other = create(:product, user: @seller, name: "Stickers", price_cents: 500)
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 5, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 6, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 2, 28, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 7, 16, 0), stripe_refunded: true)
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 8, 16, 0), chargeback_date: Time.utc(2026, 3, 9, 12, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 0, created_at: Time.utc(2026, 3, 9, 16, 0)).update!(is_bundle_product_purchase: true)
        create(:purchase, seller: @seller, link: other, price_cents: 500, created_at: Time.utc(2026, 3, 10, 16, 0))

        result = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31")

        expect(result["rows"]).to eq([
                                       { "product_id" => @product.external_id, "product_name" => "Field notes", "revenue_cents" => 3800, "units" => 2, "average_order_value_cents" => 1900 },
                                       { "product_id" => other.external_id, "product_name" => "Stickers", "revenue_cents" => 500, "units" => 1, "average_order_value_cents" => 500 }
                                     ])
        expect(result["totals"]).to eq("revenue_cents" => 4300, "units" => 3, "average_order_value_cents" => 1433)
        expect(result).to include("start_date" => "2026-03-01", "end_date" => "2026-03-31", "time_zone" => "Eastern Time (US & Canada)",
                                  "currency" => "usd", "breakdown" => "product")
      end

      it "counts a free download as a unit with no revenue" do
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 5, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 0, created_at: Time.utc(2026, 3, 6, 16, 0))

        row = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31")["rows"].first

        expect(row).to include("revenue_cents" => 1900, "units" => 2, "average_order_value_cents" => 950)
      end

      it "returns totals of zero and no rows when the range has no sales" do
        result = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31")

        expect(result["rows"]).to eq([])
        expect(result["totals"]).to eq("revenue_cents" => 0, "units" => 0, "average_order_value_cents" => nil)
      end

      it "groups by the sale's country, falling back to the IP country" do
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, country: "US", ip_country: "GB", created_at: Time.utc(2026, 3, 5, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 700, country: nil, ip_country: "DE", created_at: Time.utc(2026, 3, 6, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 500, country: nil, ip_country: nil, created_at: Time.utc(2026, 3, 7, 16, 0))

        rows = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31", "breakdown" => "country")["rows"]

        expect(rows).to eq([
                             { "country" => "US", "revenue_cents" => 1900, "units" => 1, "average_order_value_cents" => 1900 },
                             { "country" => "DE", "revenue_cents" => 700, "units" => 1, "average_order_value_cents" => 700 },
                             { "country" => nil, "revenue_cents" => 500, "units" => 1, "average_order_value_cents" => 500 }
                           ])
      end

      it "counts a commission completion's revenue but not as a second unit" do
        create(:purchase, seller: @seller, link: @product, price_cents: 4500, created_at: Time.utc(2026, 3, 5, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 4500, created_at: Time.utc(2026, 3, 6, 16, 0)).update!(is_commission_completion_purchase: true)

        result = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31")

        expect(result["totals"]).to eq("revenue_cents" => 9000, "units" => 1, "average_order_value_cents" => 9000)
        expect(result["rows"].first).to include("revenue_cents" => 9000, "units" => 1)
      end

      it "merges spellings of one country into a single row" do
        create(:purchase, seller: @seller, link: @product, price_cents: 1000, country: "South Korea", created_at: Time.utc(2026, 3, 5, 16, 0))
        create(:purchase, seller: @seller, link: @product, price_cents: 500, country: "Korea, Republic of", created_at: Time.utc(2026, 3, 6, 16, 0))

        rows = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31", "breakdown" => "country")["rows"]

        expect(rows).to eq([{ "country" => "South Korea", "revenue_cents" => 1500, "units" => 2, "average_order_value_cents" => 750 }])
      end

      it "puts a sale in the local day its own zone offset gives, across a daylight-saving change" do
        # US daylight time starts 2026-03-08; each sale sits just after local midnight in the offset in force then.
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 2, 4, 30))
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 10, 4, 30))

        rows = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31", "breakdown" => "day")["rows"]

        expect(rows.pluck("date")).to eq(["2026-03-01", "2026-03-10"])
        expect(rows).to all(include("revenue_cents" => 1900, "units" => 1, "average_order_value_cents" => 1900))
      end

      it "dates week rows on their Monday and month rows on the first of the month" do
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 10, 4, 0))

        expect(get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31", "breakdown" => "week")["rows"].first).to include("date" => "2026-03-09", "units" => 1)
        expect(get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31", "breakdown" => "month")["rows"].first).to include("date" => "2026-03-01", "units" => 1)
      end

      it "filters to one product" do
        other = create(:product, user: @seller, name: "Stickers", price_cents: 500)
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: Time.utc(2026, 3, 5, 16, 0))
        create(:purchase, seller: @seller, link: other, price_cents: 500, created_at: Time.utc(2026, 3, 6, 16, 0))

        result = get_sales_totals("start_date" => "2026-03-01", "end_date" => "2026-03-31", "product_id" => @product.external_id)

        expect(result["rows"].pluck("product_id")).to eq([@product.external_id])
        expect(result["totals"]).to eq("revenue_cents" => 1900, "units" => 1, "average_order_value_cents" => 1900)
      end

      it "defaults to the last 30 days" do
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: 10.days.ago)
        create(:purchase, seller: @seller, link: @product, price_cents: 1900, created_at: 40.days.ago)

        expect(get_sales_totals["rows"].first).to include("revenue_cents" => 1900, "units" => 1)
      end

      it "rejects bad dates, inverted ranges and ranges over a year" do
        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_sales_totals", arguments: { "start_date" => "yesterday" } } })
        expect(response.parsed_body.dig("error", "message")).to eq("start_date must be a date like 2026-10-31")

        [{ "start_date" => "2026-10-05", "end_date" => "2026-10-01" }, { "start_date" => "2024-01-01", "end_date" => "2026-01-01" }].each do |arguments|
          post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_sales_totals", arguments: } })
          expect(response.parsed_body["error"]["code"]).to eq(-32602)
        end
      end

      it "requires the view_sales scope" do
        @token.update!(scopes: "view_profile")

        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_sales_totals", arguments: {} } })

        expect(response.parsed_body.to_s).to include("view_sales")
      end
    end

    describe "list_sales pagination, filters and fields" do
      def list_sales(arguments)
        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_sales", arguments: } })
        response.parsed_body.dig("result", "structuredContent")
      end

      it "pages with a cursor without repeating or skipping sales" do
        purchases = Array.new(3) { |i| create(:purchase, seller: @seller, link: @product, created_at: (i + 1).hours.ago) }

        first = list_sales({ "limit" => 2 })
        expect(first["sales"].map { |s| s["id"] }).to eq(purchases.first(2).map(&:external_id))
        expect(first["next_cursor"]).to be_present

        second = list_sales({ "limit" => 2, "cursor" => first["next_cursor"] })
        expect(second["sales"].map { |s| s["id"] }).to eq([purchases.last.external_id])
        expect(second).not_to have_key("next_cursor")
      end

      it "breaks created_at ties by id across page boundaries" do
        at = 1.hour.ago.change(usec: 0)
        purchases = Array.new(3) { create(:purchase, seller: @seller, link: @product, created_at: at) }

        first = list_sales({ "limit" => 2 })
        second = list_sales({ "limit" => 2, "cursor" => first["next_cursor"] })

        expect((first["sales"] + second["sales"]).map { |s| s["id"] }).to match_array(purchases.map(&:external_id))
        expect(second).not_to have_key("next_cursor")
      end

      it "breaks created_at ties by id for products and payouts" do
        @token.update!(scopes: "account")
        at = 1.hour.ago.change(usec: 0)
        products = Array.new(3) { create(:product, user: @seller, created_at: at) }
        payments = Array.new(3) { create(:payment, user: @seller, created_at: at) }

        { "list_products" => ["products", Link.where(id: products.map(&:id)).map(&:external_id)],
          "list_payouts" => ["payouts", payments.map(&:external_id)] }.each do |tool, (key, expected)|
          page = ->(args) do
            post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: tool, arguments: args } })
            response.parsed_body.dig("result", "structuredContent")
          end
          seen = []
          cursor = nil
          loop do
            result = page.call({ "limit" => 2, "cursor" => cursor }.compact)
            seen += result[key].map { |row| row["id"] }
            cursor = result["next_cursor"]
            break unless cursor
          end
          expect(seen & expected).to match_array(expected)
          expect(seen).to eq(seen.uniq)
        end
      end

      it "treats installment plan payments as one-time, not subscription" do
        membership = create(:membership_purchase, seller: @seller, link: create(:membership_product, user: @seller))
        installment = create(:purchase, seller: @seller, link: @product)
        plan = create(:subscription, link: @product, user: nil)
        plan.update!(is_installment_plan: true)
        installment.update_columns(subscription_id: plan.id)

        subs = list_sales({ "kind" => "subscription" })["sales"].map { |s| s["id"] }
        one_time = list_sales({ "kind" => "one_time" })["sales"].map { |s| s["id"] }
        expect(subs).to include(membership.external_id)
        expect(subs).not_to include(installment.external_id)
        expect(one_time).to include(installment.external_id)
        expect(one_time).not_to include(membership.external_id)
        expect(list_sales({})["sales"].find { |s| s["id"] == installment.external_id }["subscription"]).to eq(false)
      end

      it "rejects a malformed cursor" do
        list_sales({ "cursor" => "nope" })
        expect(response.parsed_body.dig("error", "message")).to eq("cursor is not valid")
      end

      it "rejects a cursor or date outside the years a datetime column holds" do
        list_sales({ "cursor" => "#{Time.utc(10_000).to_i * Mcp::Server::MICROSECONDS_PER_SECOND}_1" })
        expect(response.parsed_body.dig("error", "message")).to eq("cursor is not valid")

        list_sales({ "after" => "10000-01-01" })
        expect(response.parsed_body.dig("error", "message")).to eq("after must be a date or ISO 8601 time")

        list_sales({ "before" => "9999-12-31T23:00:00-05:00" })
        expect(response.parsed_body.dig("error", "message")).to eq("before must be a date or ISO 8601 time")

        list_sales({ "after" => "-0001-01-01" })
        expect(response.parsed_body.dig("error", "message")).to eq("after must be a date or ISO 8601 time")
      end

      it "accepts dates inside the years a datetime column holds", :aggregate_failures do
        sale = create(:purchase, seller: @seller, link: @product)
        ids = ->(filter) { list_sales(filter)&.fetch("sales")&.map { |s| s["id"] } }

        expect(ids.call({ "after" => "0000-01-01" })).to eq([sale.external_id])
        expect(ids.call({ "after" => "0999-01-01" })).to eq([sale.external_id])
        expect(ids.call({ "before" => "9999-12-31" })).to eq([sale.external_id])
      end

      it "filters by product, date range, paid vs free" do
        other = create(:product, user: @seller)
        old = create(:purchase, seller: @seller, link: @product, created_at: Time.utc(2026, 9, 1, 12))
        recent = create(:purchase, seller: @seller, link: @product, created_at: Time.utc(2026, 10, 10, 12))
        free = create(:free_purchase, seller: @seller, link: other, created_at: Time.utc(2026, 10, 11, 12))

        ids = ->(args) { list_sales(args)["sales"].map { |s| s["id"] } }
        expect(ids.call({ "product_id" => other.external_id })).to eq([free.external_id])
        expect(ids.call({ "after" => "2026-10-01", "before" => "2026-10-11" })).to eq([recent.external_id])
        expect(ids.call({ "payment" => "free" })).to eq([free.external_id])
        expect(ids.call({ "payment" => "paid" })).to match_array([old.external_id, recent.external_id])
      end

      it "returns net amount, country, discount code and UTM fields" do
        purchase = create(:purchase, seller: @seller, link: @product, price_cents: 1900, country: "Jamaica", referrer: "https://example.com/post")
        purchase.update_columns(fee_cents: 250, affiliate_credit_cents: 100)

        sale = list_sales({})["sales"].find { |s| s["id"] == purchase.external_id }
        expect(sale).to include("fee_cents" => 250, "affiliate_commission_cents" => 100, "net_cents" => 1550,
                                "country" => "Jamaica", "referrer" => "https://example.com/post",
                                "subscription" => false, "discount_code" => nil, "utm_source" => nil)
      end
    end

    it "refuses a write tool" do
      expect { post_mcp({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } }) }.not_to change(Link, :count)

      expect(response.parsed_body.dig("error", "message")).to include("edit_products")
    end

    it "refuses to edit a product or add a cover" do
      allow(SsrfFilter).to receive(:get)

      expect do
        post_mcp({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "update_product", arguments: { id: @product.external_id, name: "Nope" } } })
        expect(response.parsed_body.dig("error", "message")).to include("edit_products")
        post_mcp({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "add_cover", arguments: { id: @product.external_id, url: "https://example.com/cover.png" } } })
        expect(response.parsed_body.dig("error", "message")).to include("edit_products")
      end.not_to change { [@product.reload.attributes, AssetPreview.count] }
      expect(SsrfFilter).not_to have_received(:get)
    end
  end

  context "with an edit_products token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "edit_products")
    end

    it "creates a draft and does not publish it" do
      post_mcp({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Muse draft", price_cents: 1900, description: "A note." } } })

      expect(response).to have_http_status(:ok)
      expect(response.headers["WWW-Authenticate"]).to be_nil
      payload = response.parsed_body.dig("result", "structuredContent", "product")
      expect(payload["name"]).to eq("Muse draft")
      expect(payload["published"]).to eq(false)
      product = @seller.links.find_by_external_id(payload["id"])
      expect(product).to be_draft
      expect(product.purchase_disabled_at).to be_present
    end

    describe "creating a membership" do
      let(:tiers) do
        [
          { name: "Reader", price_cents: 500, recurrence: "monthly" },
          { name: "Supporter", price_cents: 1500, recurrence: "monthly" }
        ]
      end

      it "creates a draft membership with its tiers and their recurring prices" do
        expect do
          call_tool("create_draft_product", { name: "Field club", product_type: "membership", tiers:, description: "Monthly notes." })
        end.to change(@seller.links, :count).by(1)

        payload = response.parsed_body.dig("result", "structuredContent", "product")
        product = @seller.links.find_by_external_id(payload["id"])
        expect(product.native_type).to eq(Link::NATIVE_TYPE_MEMBERSHIP)
        expect(product).to be_is_tiered_membership
        expect(product).to be_is_recurring_billing
        expect(product.subscription_duration).to eq("monthly")
        expect(product).to be_draft
        expect(product.purchase_disabled_at).to be_present
        expect(product.taxonomy.slug).to eq("other")
        expect(product.description).to eq("Monthly notes.")
        expect(product.should_show_all_posts).to eq(true)
        expect(product.should_include_last_post).to eq(true)

        created_tiers = product.tiers.alive.order(:position_in_category)
        expect(created_tiers.map(&:name)).to eq(%w[Reader Supporter])
        expect(created_tiers.map { _1.alive_prices.is_buy.pluck(:recurrence, :price_cents) }).to eq([[["monthly", 500]], [["monthly", 1500]]])
        expect(product.alive_prices.is_buy.pluck(:recurrence, :price_cents)).to eq([["monthly", 0]])

        expect(payload).to include("published" => false, "price_cents" => nil, "pay_what_you_want" => false)
        expect(payload["tiers"]).to eq([
                                         { "id" => created_tiers.first.external_id, "name" => "Reader", "pay_what_you_want" => false,
                                           "prices" => { "monthly" => { "price_cents" => 500, "suggested_price_cents" => nil } } },
                                         { "id" => created_tiers.second.external_id, "name" => "Supporter", "pay_what_you_want" => false,
                                           "prices" => { "monthly" => { "price_cents" => 1500, "suggested_price_cents" => nil } } }
                                       ])
      end

      it "uses the tiers' recurrence as the billing period" do
        call_tool("create_draft_product", { name: "Annual club", product_type: "membership", tiers: [{ name: "Member", price_cents: 5000, recurrence: "yearly" }] })

        product = @seller.links.find_by_external_id(response.parsed_body.dig("result", "structuredContent", "product", "id"))
        expect(product.subscription_duration).to eq("yearly")
        expect(product.tiers.alive.sole.alive_prices.is_buy.pluck(:recurrence, :price_cents)).to eq([["yearly", 5000]])
      end

      it "makes a $0 tier pay what you want, as the editor does" do
        call_tool("create_draft_product", { name: "Open club", product_type: "membership", tiers: [{ name: "Paid", price_cents: 500, recurrence: "monthly" }, { name: "Free", price_cents: 0, recurrence: "monthly" }] })

        tiers = response.parsed_body.dig("result", "structuredContent", "product", "tiers")
        expect(tiers.map { _1.slice("name", "pay_what_you_want") }).to eq([{ "name" => "Paid", "pay_what_you_want" => false }, { "name" => "Free", "pay_what_you_want" => true }])
      end

      it "reports a tier price below the currency minimum as a tool error and creates nothing" do
        expect do
          call_tool("create_draft_product", { name: "Cheap club", product_type: "membership", tiers: [{ name: "Member", price_cents: 10, recurrence: "monthly" }] })
        end.not_to change { [Link.count, BaseVariant.count, BasePrice.count] }

        expect(response.parsed_body.dig("result", "isError")).to eq(true)
        expect(response.parsed_body.dig("result", "content", 0, "text")).to include("must be at least")
      end

      it "rolls back the whole membership when a later tier is priced below the currency minimum" do
        expect do
          call_tool("create_draft_product", { name: "Half club", product_type: "membership", tiers: [{ name: "Reader", price_cents: 500, recurrence: "monthly" }, { name: "Cheap", price_cents: 10, recurrence: "monthly" }] })
        end.not_to change { [Link.count, VariantCategory.count, BaseVariant.count, BasePrice.count] }

        expect(response.parsed_body.dig("result", "isError")).to eq(true)
        expect(response.parsed_body.dig("result", "content", 0, "text")).to include("must be at least")
      end

      {
        "no tiers" => [{ product_type: "membership" }, "tiers are required for a membership"],
        "an empty tier list" => [{ product_type: "membership", tiers: [] }, "tiers are required for a membership"],
        "tiers on a digital product" => [{ product_type: "digital", price_cents: 500, tiers: [{ name: "A", price_cents: 500, recurrence: "monthly" }] }, "tiers are only accepted with product_type membership"],
        "tiers with no product_type" => [{ price_cents: 500, tiers: [{ name: "A", price_cents: 500, recurrence: "monthly" }] }, "tiers are only accepted with product_type membership"],
        "a bad recurrence" => [{ product_type: "membership", tiers: [{ name: "A", price_cents: 500, recurrence: "weekly" }] }, "tiers[0].recurrence must be one of: monthly, quarterly, biannually, yearly, every_two_years"],
        "mixed recurrences" => [{ product_type: "membership", tiers: [{ name: "A", price_cents: 500, recurrence: "monthly" }, { name: "B", price_cents: 5000, recurrence: "yearly" }] }, "every tier must use the same recurrence"],
        "a negative tier price" => [{ product_type: "membership", tiers: [{ name: "A", price_cents: -1, recurrence: "monthly" }] }, "tiers[0].price_cents must be an integer of zero or more"],
        "a later tier priced over the maximum" => [{ product_type: "membership", tiers: [{ name: "A", price_cents: 500, recurrence: "monthly" }, { name: "B", price_cents: BasePrice::Shared::MAX_PRICE_CENTS + 1, recurrence: "monthly" }] }, "tiers[1].price_cents must be at most #{BasePrice::Shared::MAX_PRICE_CENTS}"],
        "a fractional tier price" => [{ product_type: "membership", tiers: [{ name: "A", price_cents: 4.5, recurrence: "monthly" }] }, "tiers[0].price_cents must be an integer of zero or more"],
        "a blank tier name" => [{ product_type: "membership", tiers: [{ name: " ", price_cents: 500, recurrence: "monthly" }] }, "tiers[0].name must be a non-blank string"],
        "a tier missing its recurrence" => [{ product_type: "membership", tiers: [{ name: "A", price_cents: 500 }] }, "tiers[0].recurrence is required"],
        "an unknown tier argument" => [{ product_type: "membership", tiers: [{ name: "A", price_cents: 500, recurrence: "monthly", pay_what_you_want: true }] }, "tiers[0] has unknown argument: pay_what_you_want"],
        "a tier that is not an object" => [{ product_type: "membership", tiers: ["Reader"] }, "tiers[0] must be an object"],
        "tiers that are not a list" => [{ product_type: "membership", tiers: { name: "A" } }, "tiers must be an array"],
        "a top-level price on a membership" => [{ product_type: "membership", price_cents: 500, tiers: [{ name: "A", price_cents: 500, recurrence: "monthly" }] }, "price_cents is not accepted for a membership; set each tier's price_cents"],
        "a digital product with no price" => [{ product_type: "digital" }, "price_cents is required"],
      }.each do |label, (arguments, message)|
        it "rejects #{label} without creating a product" do
          expect { call_tool("create_draft_product", { name: "Club", **arguments }) }.not_to change(Link, :count)

          expect(response.parsed_body["error"]).to eq("code" => -32602, "message" => message)
        end
      end

      %w[physical call bundle commission podcast coffee Membership].each do |product_type|
        it "rejects product_type #{product_type}" do
          expect do
            call_tool("create_draft_product", { name: "Other", price_cents: 500, product_type:, tiers: [{ name: "A", price_cents: 500, recurrence: "monthly" }] })
          end.not_to change(Link, :count)

          expect(response.parsed_body["error"]).to eq("code" => -32602, "message" => "product_type must be one of: digital, membership")
        end
      end

      it "creates a digital product exactly as before when product_type is digital" do
        call_tool("create_draft_product", { name: "Field guide", price_cents: 1900, product_type: "digital" })

        payload = response.parsed_body.dig("result", "structuredContent", "product")
        product = @seller.links.find_by_external_id(payload["id"])
        expect(product.native_type).to eq(Link::NATIVE_TYPE_DIGITAL)
        expect(product.price_cents).to eq(1900)
        expect(product).not_to be_is_tiered_membership
        expect(product.variant_categories).to be_empty
        expect(payload).to include("price_cents" => 1900)
        expect(payload).not_to have_key("tiers")
      end
    end

    it "answers a batch with per-message errors and no challenge, so a retry cannot repeat the write" do
      batch = [
        { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Once", price_cents: 500 } } },
        { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_payouts", arguments: {} } }
      ]

      expect { post_mcp(batch) }.to change(Link, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.headers["WWW-Authenticate"]).to be_nil
      results = response.parsed_body.index_by { |message| message["id"] }
      expect(results.dig(1, "result", "structuredContent", "product", "name")).to eq("Once")
      expect(results.dig(2, "error")).to eq("code" => -32000, "message" => "This tool requires the view_payouts or account scope.")
    end

    it "publishes an existing product the seller owns" do
      @product.update!(draft: true, purchase_disabled_at: Time.current)

      post_mcp({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "publish_product", arguments: { id: @product.external_id } } })

      expect(response).to be_successful
      expect(response.parsed_body.dig("result", "structuredContent", "product", "published")).to eq(true)
      expect(@product.reload).to be_published
    end

    it "does not publish a product Gumroad has put on a sales hold" do
      @product.hold_sales!(seller: @seller, held_by: create(:admin_user))

      post_mcp({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "publish_product", arguments: { id: @product.external_id } } })

      expect(response).to be_successful
      expect(response.parsed_body["result"]).to include("isError" => true, "content" => [{ "type" => "text", "text" => Link::UNPUBLISHED_BY_ADMIN_MESSAGE }])
      expect(@product.reload.purchase_disabled_at).to be_present
    end

    def call_tool(name, arguments)
      post_mcp({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name:, arguments: } })
    end

    it "updates the name, description, and price of a published product" do
      call_tool("update_product", { id: @product.unique_permalink, name: "Field notes, vol. 2", description: "<p>Now with maps.</p>", price_cents: 2500 })

      expect(response).to be_successful
      payload = response.parsed_body.dig("result", "structuredContent", "product")
      expect(payload).to include("name" => "Field notes, vol. 2", "price_cents" => 2500, "published" => true, "description" => "<p>Now with maps.</p>")
      @product.reload
      expect(@product.name).to eq("Field notes, vol. 2")
      expect(@product.description).to eq("<p>Now with maps.</p>")
      expect(@product.price_cents).to eq(2500)
    end

    it "changes only the fields it is given" do
      @product.update!(description: "Original")

      call_tool("update_product", { id: @product.external_id, description: "Rewritten" })

      expect(response).to be_successful
      @product.reload
      expect(@product.description).to eq("Rewritten")
      expect(@product.name).to eq("Field notes")
      expect(@product.price_cents).to eq(1900)
    end

    it "changes the URL and keeps the old one pointing at the product" do
      @product.update!(custom_permalink: "field-notes-original")

      call_tool("update_product", { id: @product.external_id, permalink: "field-notes-renamed" })

      expect(response).to be_successful
      @product.reload
      expect(@product.custom_permalink).to eq("field-notes-renamed")
      expect(response.parsed_body.dig("result", "structuredContent", "product", "url")).to eq(@product.long_url)
      expect(Link.fetch_leniently("field-notes-original", user: @seller)).to eq(@product)
    end

    it "gives a product its first custom URL" do
      call_tool("update_product", { id: @product.external_id, permalink: "field-notes-first" })

      expect(response).to be_successful
      @product.reload
      expect(@product.custom_permalink).to eq("field-notes-first")
      expect(@product.long_url).to end_with("/l/field-notes-first")
    end

    it "clears the custom URL back to the default one" do
      @product.update!(custom_permalink: "field-notes-temporary")

      call_tool("update_product", { id: @product.external_id, permalink: "" })

      expect(response).to be_successful
      @product.reload
      expect(@product.custom_permalink).to be_nil
      expect(@product.long_url).to end_with("/l/#{@product.unique_permalink}")
      expect(Link.fetch_leniently("field-notes-temporary", user: @seller)).to eq(@product)
    end

    it "rejects a URL with characters the editor does not allow" do
      expect { call_tool("update_product", { id: @product.external_id, permalink: "field notes!" }) }
        .not_to change { @product.reload.attributes }

      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content", 0, "text"))
        .to eq("Custom permalink can only contain letters, numbers, dashes, and underscores")
    end

    it "rejects a URL another of the seller's products already uses" do
      create(:product, user: @seller, name: "Other notes", custom_permalink: "field-notes-taken")

      expect { call_tool("update_product", { id: @product.external_id, permalink: "field-notes-taken" }) }
        .not_to change { @product.reload.attributes }

      expect(response.parsed_body.dig("result", "content", 0, "text"))
        .to eq("Custom permalink is already used by another one of your products")
    end

    it "refuses a whitespace-only permalink instead of clearing the URL" do
      @product.update!(custom_permalink: "field-notes-kept")

      expect { call_tool("update_product", { id: @product.external_id, permalink: "   " }) }
        .not_to change { @product.reload.attributes }

      expect(response.parsed_body["error"]).to include(
        "code" => -32602, "message" => "permalink must not be blank. Send an empty string to go back to the default URL."
      )
    end

    it "leaves the URL and the redirect rows alone when the permalink is unchanged" do
      @product.update!(custom_permalink: "field-notes-same")

      expect { call_tool("update_product", { id: @product.external_id, permalink: "field-notes-same" }) }
        .not_to change { [ProductPermalinkRedirect.count, LegacyPermalink.count, @product.reload.custom_permalink] }

      expect(response.parsed_body["error"]).to be_nil
      expect(response.parsed_body.dig("result", "structuredContent", "product", "url")).to end_with("/l/field-notes-same")
    end

    it "takes the seller row before the product row when it changes the URL" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql].to_s }
      begin
        call_tool("update_product", { id: @product.external_id, permalink: "field-notes-locked" })
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(response.parsed_body.dig("result", "isError")).to be_nil
      seller_lock = statements.index { _1.include?("FROM `users`") && _1.include?("FOR UPDATE") }
      product_lock = statements.index { _1.include?("FROM `links`") && _1.include?("FOR UPDATE") }
      expect(seller_lock).to be_present
      expect(seller_lock).to be < product_lock
    end

    it "saves nothing and asks for a retry when another save moves the URL while it waits for the lock" do
      @product.update!(custom_permalink: "field-notes-before")
      allow_any_instance_of(Link).to receive(:lock!).and_wrap_original do |original, *args|
        Link.where(id: @product.id).update_all(custom_permalink: "field-notes-concurrent")
        original.call(*args)
      end

      expect { call_tool("update_product", { id: @product.external_id, name: "Field notes, vol. 3", permalink: "field-notes-before" }) }
        .not_to change { [@product.reload.attributes, ProductPermalinkRedirect.count, LegacyPermalink.count] }

      expect(response.parsed_body["result"]).to include(
        "isError" => true,
        "content" => [{ "type" => "text", "text" => "This product's URL changed while the update was waiting. Nothing was saved; try the update again." }]
      )
    end

    it "rejects an update with no fields to change" do
      expect { call_tool("update_product", { id: @product.external_id }) }.not_to change { @product.reload.attributes }

      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "Pass at least one of name, description, price_cents, or permalink")
    end

    it "rejects a blank name without changing the product" do
      expect { call_tool("update_product", { id: @product.external_id, name: "  ", description: "Kept out" }) }.not_to change { @product.reload.attributes }

      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "name must not be blank")
    end

    it "warns when a lower price pushes an existing discount below the minimum" do
      create(:offer_code, user: @seller, products: [@product], code: "save18", amount_cents: 1800)

      call_tool("update_product", { id: @product.external_id, price_cents: 1850 })

      expect(response).to be_successful
      content = response.parsed_body.dig("result", "structuredContent")
      expect(content.dig("product", "price_cents")).to eq(1850)
      expect(content["warning"]).to include("save18")
    end

    it "rolls back the whole update when the product fails validation" do
      expect do
        call_tool("update_product", { id: @product.external_id, price_cents: 1, description: "Kept out" })
      end.not_to change { [@product.reload.attributes, @product.prices.map(&:attributes)] }

      expect(response.parsed_body.dig("result", "isError")).to eq(true)
    end

    it "refuses a price change on a membership with tiers and leaves its prices unchanged" do
      membership = create(:membership_product_with_preset_tiered_pricing, user: @seller)

      expect do
        call_tool("update_product", { id: membership.external_id, price_cents: 100 })
      end.not_to change { [membership.reload.attributes, membership.alive_prices.map(&:attributes)] }

      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content", 0, "text")).to include("membership with tiers")
    end

    it "refuses to update another seller's product" do
      other_product = create(:product, name: "Theirs")

      expect { call_tool("update_product", { id: other_product.external_id, name: "Mine now" }) }.not_to change { other_product.reload.attributes }

      expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
    end

    def http_response(response_class, code, body: "", content_type: "text/html")
      response = response_class.new("1.1", code, Rack::Utils::HTTP_STATUS_CODES[code.to_i])
      response["Content-Type"] = content_type
      allow(response).to receive(:body).and_return(body)
      response
    end

    it "adds a cover from an image URL" do
      image = File.binread(Rails.root.join("spec/support/fixtures/kFDzu.png"))
      allow(SsrfFilter).to receive(:get).with("https://example.com/cover.png").and_return(http_response(Net::HTTPOK, "200", body: image, content_type: "image/png"))

      expect { call_tool("add_cover", { id: @product.external_id, url: "https://example.com/cover.png" }) }.to change { @product.asset_previews.alive.count }.by(1)

      expect(response).to be_successful
      covers = response.parsed_body.dig("result", "structuredContent", "covers")
      cover = @product.asset_previews.alive.last
      expect(covers).to eq([{ "id" => cover.guid, "url" => cover.url, "type" => "image" }])
      expect(cover.file).to be_attached
      expect([cover.width, cover.height]).to eq([1633, 512])
    end

    it "reports a URL it cannot fetch as a tool error without adding a cover" do
      allow(SsrfFilter).to receive(:get).and_raise(SsrfFilter::PrivateIPAddress)

      expect { call_tool("add_cover", { id: @product.external_id, url: "https://example.com/internal.png" }) }.not_to change { AssetPreview.count }

      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content", 0, "text")).to include("Could not fetch an image from that URL")
    end

    it "names the HTTP status when the cover URL is a broken link, without adding a cover" do
      allow(SsrfFilter).to receive(:get).and_return(http_response(Net::HTTPNotFound, "404", body: "<html>Not found</html>"))

      expect { call_tool("add_cover", { id: @product.external_id, url: "https://example.com/missing.png" }) }.not_to change { AssetPreview.count }

      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content", 0, "text")).to eq("Could not fetch an image from that URL. The link returned HTTP 404 Not Found. Use a public https link to the image file.")
    end

    it "returns a product's covers, main cover first" do
      second = create(:asset_preview, link: @product)
      first = create(:asset_preview, link: @product)
      @product.reorder_previews(first.guid => 0, second.guid => 1)

      call_tool("get_product", { id: @product.external_id })

      covers = response.parsed_body.dig("result", "structuredContent", "product", "covers")
      expect(covers.map { _1["id"] }).to eq([first.guid, second.guid])
      expect(covers.first).to eq("id" => first.guid, "url" => first.reload.url, "type" => "image")
    end

    it "refuses a cover for another seller's product without fetching the URL" do
      other_product = create(:product)
      allow(SsrfFilter).to receive(:get)

      expect { call_tool("add_cover", { id: other_product.external_id, url: "https://example.com/cover.png" }) }.not_to change { AssetPreview.count }

      expect(SsrfFilter).not_to have_received(:get)
      expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
    end

    describe "bundles" do
      let!(:member) { create(:product, user: @seller, name: "Second notes") }

      it "creates a draft bundle that sells the products it is given, in order" do
        expect do
          call_tool("create_bundle", { name: "Field kit", price_cents: 4500, product_ids: [@product.external_id, member.unique_permalink] })
        end.to change { @seller.links.count }.by(1)

        expect(response).to be_successful
        content = response.parsed_body.dig("result", "structuredContent")
        bundle = @seller.links.find_by_external_id!(content.dig("product", "id"))
        expect(bundle).to be_is_bundle
        expect(bundle.native_type).to eq(Link::NATIVE_TYPE_BUNDLE)
        expect(bundle).to be_draft
        expect(content["product"]).to include("name" => "Field kit", "price_cents" => 4500, "published" => false, "is_bundle" => true)
        expect(content["bundle_products"]).to eq([
                                                   { "id" => @product.external_id, "name" => "Field notes", "variant_id" => nil, "quantity" => 1 },
                                                   { "id" => member.external_id, "name" => "Second notes", "variant_id" => nil, "quantity" => 1 }
                                                 ])
        expect(content["message"]).to include("not for sale until publish_product")
        expect(bundle.bundle_products.alive.in_order.map { _1.product.external_id }).to eq([@product.external_id, member.external_id])
      end

      it "adds a product sold in versions at its first version" do
        versioned = create(:product_with_digital_versions, user: @seller, name: "Print")

        call_tool("create_bundle", { name: "Field kit", price_cents: 4500, product_ids: [versioned.external_id] })

        expect(response).to be_successful
        bundle = @seller.links.find_by_name("Field kit")
        expect(bundle.bundle_products.alive.sole.variant).to eq(versioned.variants_or_skus.first)
      end

      it "keeps the version a retained member already sells" do
        versioned = create(:product_with_digital_versions, user: @seller, name: "Print")
        chosen = versioned.alive_variants.last
        expect(chosen).not_to eq(versioned.variants_or_skus.first)
        bundle = create(:product, :bundle, user: @seller)
        bundle.bundle_products.create!(product: versioned, variant: chosen, quantity: 1, position: 0)

        call_tool("update_bundle", { id: bundle.external_id, product_ids: [versioned.external_id, member.external_id] })

        expect(response).to be_successful
        content = response.parsed_body.dig("result", "structuredContent")
        expect(content["bundle_products"].first).to include("id" => versioned.external_id, "variant_id" => chosen.external_id)
        expect(bundle.reload.bundle_products.alive.find_by(product_id: versioned.id).variant).to eq(chosen)
      end

      it "keeps the quantity a retained member already sells, and adds a new member once" do
        bundle = create(:product, :bundle, user: @seller)
        kept = bundle.bundle_products.alive.in_order.first
        kept.update!(quantity: 3)

        call_tool("update_bundle", { id: bundle.external_id, product_ids: [kept.product.external_id, member.external_id] })

        expect(response).to be_successful
        expect(kept.reload.quantity).to eq(3)
        expect(bundle.reload.bundle_products.alive.find_by!(product: member).quantity).to eq(1)
        expect(response.parsed_body.dig("result", "structuredContent", "bundle_products").map { _1["quantity"] }).to eq([3, 1])
      end

      it "leaves a bundle's members alone when one of the new ids is unknown" do
        bundle = create(:product, :bundle, user: @seller)
        kept = bundle.bundle_products.alive.in_order.first

        expect do
          call_tool("update_bundle", { id: bundle.external_id, product_ids: [kept.product.external_id, "no-such-product"] })
        end.not_to change { bundle.reload.bundle_products.alive.map(&:product_id) }

        expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
      end

      it "creates nothing when a later id belongs to another seller" do
        theirs = create(:product, name: "Theirs")

        expect do
          call_tool("create_bundle", { name: "Half mine", price_cents: 100, product_ids: [@product.external_id, theirs.external_id] })
        end.not_to change { [Link.count, BundleProduct.count] }

        expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
      end

      it "refuses a product id that is not a string" do
        expect { call_tool("create_bundle", { name: "Numbers", price_cents: 100, product_ids: [@product.external_id, 123] }) }.not_to change { Link.count }

        expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "product_ids[1] must be a non-blank string")
      end

      it "refuses a blank product id" do
        expect { call_tool("create_bundle", { name: "Blank", price_cents: 100, product_ids: ["  "] }) }.not_to change { Link.count }

        expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "product_ids[0] must be a non-blank string")
      end

      it "gives a retained member its product's first version once that product is sold in versions" do
        bundle = create(:product, :bundle, user: @seller)
        kept = bundle.bundle_products.alive.in_order.first
        category = create(:variant_category, title: "Format", link: kept.product)
        create(:variant, variant_category: category, name: "PDF")
        create(:variant, variant_category: category, name: "EPUB")

        call_tool("update_bundle", { id: bundle.external_id, product_ids: [kept.product.external_id] })

        expect(response).to be_successful
        expect(kept.reload).to have_attributes(variant: kept.product.reload.variants_or_skus.first, deleted_at: nil)
        expect(kept.variant).to be_present
      end

      it "re-adds a removed member with the defaults rather than its old version" do
        versioned = create(:product_with_digital_versions, user: @seller, name: "Print")
        bundle = create(:product, :bundle, user: @seller)
        removed = bundle.bundle_products.create!(product: versioned, variant: versioned.alive_variants.last, quantity: 2, position: 2)
        removed.mark_deleted!

        call_tool("update_bundle", { id: bundle.external_id, product_ids: [versioned.external_id] })

        expect(response).to be_successful
        expect(removed.reload).to have_attributes(deleted_at: nil, variant: versioned.variants_or_skus.first, quantity: 1)
      end

      it "refuses an empty product list without creating anything" do
        expect { call_tool("create_bundle", { name: "Empty", price_cents: 100, product_ids: [] }) }.not_to change { Link.count }

        expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "product_ids must name at least one product")
      end

      it "refuses a product_ids value that is not a list" do
        expect { call_tool("create_bundle", { name: "Empty", price_cents: 100, product_ids: "field-notes" }) }.not_to change { Link.count }

        expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "product_ids must be an array")
      end

      it "refuses another seller's product and creates nothing" do
        theirs = create(:product, name: "Theirs")

        expect { call_tool("create_bundle", { name: "Mine now", price_cents: 100, product_ids: [theirs.external_id] }) }.not_to change { [Link.count, BundleProduct.count] }

        expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
      end

      it "creates nothing when one of the products cannot go in a bundle" do
        membership = create(:membership_product, user: @seller)

        expect do
          call_tool("create_bundle", { name: "Half made", price_cents: 100, product_ids: [@product.external_id, membership.external_id] })
        end.not_to change { [Link.count, BundleProduct.count] }

        expect(response.parsed_body.dig("result", "content", 0, "text")).to include("A subscription product cannot be added to a bundle")
      end

      it "replaces the products a bundle sells, keeping its name, price, and published state" do
        bundle = create(:product, :bundle, user: @seller, name: "Field kit", price_cents: 4500)

        call_tool("update_bundle", { id: bundle.unique_permalink, product_ids: [member.external_id] })

        expect(response).to be_successful
        content = response.parsed_body.dig("result", "structuredContent")
        expect(content["bundle_products"]).to eq([{ "id" => member.external_id, "name" => "Second notes", "variant_id" => nil, "quantity" => 1 }])
        expect(bundle.reload.bundle_products.alive.map { _1.product.external_id }).to eq([member.external_id])
        expect(bundle.name).to eq("Field kit")
        expect(bundle.price_cents).to eq(4500)
        expect(bundle).to be_published
      end

      it "soft deletes the members it was not handed, and keeps the order it was given" do
        bundle = create(:product, :bundle, user: @seller)
        dropped, kept = bundle.bundle_products.alive.in_order.to_a

        call_tool("update_bundle", { id: bundle.external_id, product_ids: [kept.product.external_id, member.external_id] })

        expect(response).to be_successful
        expect(dropped.reload).to be_deleted
        expect(bundle.reload.bundle_products.alive.in_order.map { _1.product.external_id }).to eq([kept.product.external_id, member.external_id])
      end

      it "changes nothing when one of the products cannot go in a bundle" do
        bundle = create(:product, :bundle, user: @seller)
        membership = create(:membership_product, user: @seller)

        expect do
          call_tool("update_bundle", { id: bundle.external_id, product_ids: [member.external_id, membership.external_id] })
        end.not_to change { bundle.reload.bundle_products.alive.map(&:product_id) }

        expect(response.parsed_body.dig("result", "content", 0, "text")).to include("A subscription product cannot be added to a bundle")
      end

      it "refuses a product that is not a bundle, without turning it into one" do
        call_tool("update_bundle", { id: @product.external_id, product_ids: [member.external_id] })

        expect(response.parsed_body.dig("result", "content", 0, "text")).to eq("This product is not a bundle. Make one with create_bundle first.")
        expect(@product.reload).not_to be_is_bundle
        expect(@product.bundle_products).to be_empty
      end

      it "refuses another seller's bundle" do
        theirs = create(:product, :bundle, name: "Theirs")

        expect { call_tool("update_bundle", { id: theirs.external_id, product_ids: [member.external_id] }) }.not_to change { theirs.reload.bundle_products.alive.map(&:product_id) }

        expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
      end

      it "reads a bundle's products back, and leaves a single product's details alone" do
        bundle = create(:product, :bundle, user: @seller)

        call_tool("get_product", { id: bundle.external_id })
        content = response.parsed_body.dig("result", "structuredContent", "product")
        expect(content["is_bundle"]).to eq(true)
        expect(content["bundle_products"].map { _1["id"] }).to eq(bundle.bundle_products.alive.in_order.map { _1.product.external_id })

        call_tool("get_product", { id: @product.external_id })
        expect(response.parsed_body.dig("result", "structuredContent", "product")).not_to have_key("bundle_products")
      end
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
      expect(response.headers["WWW-Authenticate"]).to be_nil
      names = response.parsed_body.dig("result", "structuredContent", "products").map { |product| product["name"] }
      expect(names).to include("Field notes")
    end

    it "refuses a write tool with a 403 step-up challenge that keeps the token's scopes" do
      expect { post_mcp({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } }) }.not_to change(Link, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.headers["WWW-Authenticate"]).to eq(
        %(Bearer realm="Gumroad", error="insufficient_scope", scope="view_public edit_products", ) +
        %(resource_metadata="#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/muse/v1/mcp", ) +
        %(error_description="This tool requires the edit_products or account scope.")
      )
      expect(response.parsed_body["error"]).to eq("code" => -32000, "message" => "This tool requires the edit_products or account scope.")
    end

    it "rejects bad membership arguments before asking for edit_products" do
      expect { post_mcp({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Club", product_type: "membership" } } }) }.not_to change(Link, :count)

      expect(response).to have_http_status(:ok)
      expect(response.headers["WWW-Authenticate"]).to be_nil
      expect(response.parsed_body["error"]).to eq("code" => -32602, "message" => "tiers are required for a membership")
    end

    it "names a required scope the client registered when the first one is unregistered" do
      @app.update!(scopes: "view_public account")

      post_mcp({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } })

      expect(response).to have_http_status(:forbidden)
      expect(response.headers["WWW-Authenticate"]).to include(%(error="insufficient_scope", scope="view_public account"))
    end

    it "gives no step-up when the client registered none of the accepted scopes" do
      @app.update!(scopes: "view_public view_sales")

      expect { post_mcp({ jsonrpc: "2.0", id: 11, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } }) }.not_to change(Link, :count)

      expect(response).to have_http_status(:ok)
      expect(response.headers["WWW-Authenticate"]).to be_nil
      expect(response.parsed_body["error"]).to eq("code" => -32000, "message" => "This tool requires the edit_products or account scope.")
    end

    it "names the payouts scope when list_payouts is refused" do
      post_mcp({ jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "list_payouts", arguments: {} } })

      expect(response).to have_http_status(:forbidden)
      expect(response.headers["WWW-Authenticate"]).to include(%(error="insufficient_scope", scope="view_public view_payouts"))
      expect(response.parsed_body.dig("error", "message")).to eq("This tool requires the view_payouts or account scope.")
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

        expect(response).to have_http_status(:forbidden)
        expect(response.headers["WWW-Authenticate"]).to include(%(error="insufficient_scope", scope="view_public edit_products"))
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

  context "with a client on the 2026-07-28 revision" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
      Feature.activate(:mcp_protocol_2026_07_28)
    end

    def declared_request(method, version: Mcp::Server::MODERN_PROTOCOL_VERSION, **params)
      request = { jsonrpc: "2.0", id: 1, method: method, _meta: { Mcp::Server::VERSION_META_KEY => version } }
      request[:params] = params if params.any?
      request
    end

    def post_declared(payload, headers: {}, declared: Mcp::Server::MODERN_PROTOCOL_VERSION)
      post "/muse/v1/mcp", params: payload.to_json, headers: {
        "CONTENT_TYPE" => "application/json",
        "HOST" => DOMAIN,
        "Authorization" => "Bearer #{@token.token}",
        Mcp::Server::VERSION_HEADER => declared,
        Mcp::Server::METHOD_HEADER => payload[:method].to_s
      }.merge(headers).compact
    end

    def undeclared_headers
      { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}" }
    end

    # Bytes captured from the pre-change head on /muse, /claude and /chatgpt; an undeclared
    # client must keep getting exactly these.
    def legacy_initialize_body
      <<~'JSON'.chomp
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"gumroad","title":"Gumroad","version":"1.0.0"},"instructions":"Use these tools for a connected creator's own store: products, sales, and payouts. Confirm with the person before publishing or unpublishing. Buyers still check out on the product URL. This server does not take payment."}}
      JSON
    end

    def legacy_tools_body
      <<~'JSON'.chomp
        {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"get_account","title":"Get account","description":"The connected creator's public profile: name, username, storefront URL, currency.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"list_products","title":"List products","description":"List the creator's products (newest first). Returns id, name, price, published state, whether it is a bundle, and URL.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Max products to return (1-50, default 25)."},"cursor":{"type":"string","description":"next_cursor from the previous page."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"get_product","title":"Get product","description":"Fetch one product by id or permalink, with its description and covers, and the products a bundle sells. The first cover is the main one.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"create_draft_product","title":"Create draft product","description":"Create a draft digital product, or a draft membership with tiers billed on a recurring period. It is not for sale until publish_product runs. Confirm the name and prices with the creator first.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Product name."},"price_cents":{"type":"integer","description":"Price in minor units (cents for USD). Use 0 for a free product. Required for a digital product; not accepted for a membership, whose prices are set on its tiers."},"description":{"type":"string","description":"HTML or plain-text description."},"product_type":{"type":"string","enum":["digital","membership"],"description":"digital (default) or membership."},"tiers":{"type":"array","minItems":1,"description":"Membership tiers, in display order. Required for a membership, not accepted otherwise. Every tier must use the same recurrence.","items":{"type":"object","properties":{"name":{"type":"string","description":"Tier name."},"price_cents":{"type":"integer","description":"Price per billing period in minor units of the creator's currency. 0 makes the tier pay what you want."},"recurrence":{"type":"string","enum":["monthly","quarterly","biannually","yearly","every_two_years"],"description":"Billing period."}},"required":["name","price_cents","recurrence"],"additionalProperties":false}}},"additionalProperties":false,"required":["name"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":false}},{"name":"update_product","title":"Update product","description":"Change the name, description, price, or URL of an existing product. Pass only the fields to change. The new description replaces the old one. Confirm the changes with the creator first.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."},"name":{"type":"string","description":"New product name."},"description":{"type":"string","description":"New HTML or plain-text description."},"price_cents":{"type":"integer","description":"New price in minor units of the product's currency. Not available for memberships with tiers."},"permalink":{"type":"string","description":"New URL slug, the part after /l/. Letters, numbers, dashes, and underscores only. The old URL keeps working. Send an empty string to go back to the default URL."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":true}},{"name":"add_cover","title":"Add cover","description":"Add a cover image or video to a product from a public URL. The first cover is the main one on the product page.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."},"url":{"type":"string","description":"Public https URL of an image, or a YouTube or Vimeo link."}},"additionalProperties":false,"required":["id","url"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":false}},{"name":"list_files","title":"List files","description":"The files a buyer receives with this product: name, type, size, and position. The download page lists them in this order.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"add_file","title":"Add file","description":"Add a file that buyers receive with the product, from a public https URL. Files up to 250 MB; larger files, like a long video, must be uploaded in the product editor. Ask the creator for the link if they have not given one.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."},"url":{"type":"string","description":"Public https URL of the file."},"display_name":{"type":"string","description":"Name shown to the buyer. Defaults to the name in the URL."}},"additionalProperties":false,"required":["id","url"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":false}},{"name":"publish_product","title":"Publish product","description":"Make a draft product purchasable. Confirm with the creator first.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":true}},{"name":"unpublish_product","title":"Unpublish product","description":"Take a product off sale without deleting it.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":true}},{"name":"list_sales","title":"List sales","description":"Successful sales, newest first, with net amount, fees, country, discount code, affiliate commission, referrer and UTM fields. Free downloads count as sales; use payment=paid to skip them. When next_cursor is returned, pass it as cursor for the next page.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Max sales to return (1-50, default 25)."},"cursor":{"type":"string","description":"next_cursor from the previous page."},"email":{"type":"string","description":"Filter by buyer email."},"product_id":{"type":"string","description":"Only sales of this product (id from list_products)."},"after":{"type":"string","description":"Only sales on or after this date or ISO 8601 time (UTC), e.g. 2026-10-01."},"before":{"type":"string","description":"Only sales before this date or ISO 8601 time (UTC), e.g. 2026-11-01."},"payment":{"type":"string","enum":["paid","free"],"description":"paid = price above zero, free = zero-price sales."},"kind":{"type":"string","enum":["subscription","one_time"],"description":"subscription = membership charges, one_time = everything else."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"get_analytics","title":"Get analytics","description":"Product page views, sales and revenue for a date range, so conversion rate (sales / views) can be computed. breakdown=product (default) gives one row per product; breakdown=referrer gives views, sales and revenue per traffic source. Revenue is price minus refunds and chargebacks, before fees, in minor units of USD. Dates are in the creator's time zone and default to the last 30 days.","inputSchema":{"type":"object","properties":{"start_date":{"type":"string","description":"First day, YYYY-MM-DD. Defaults to 29 days before end_date."},"end_date":{"type":"string","description":"Last day, YYYY-MM-DD. Defaults to today."},"product_id":{"type":"string","description":"Only this product (id from list_products)."},"breakdown":{"type":"string","enum":["product","referrer"],"description":"product (default) or referrer."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"get_sales_totals","title":"Get sales totals","description":"Revenue, units and average order value for a date range, grouped by product, country or period. Counts sales that still stand: successful or preorder-authorized sales not refunded or charged back, free downloads included. Revenue is price before fees, in minor units of USD, and average_order_value_cents is revenue_cents divided by units. Dates are in the creator's time zone and default to the last 30 days. Product and country rows are the top 100 by revenue.","inputSchema":{"type":"object","properties":{"start_date":{"type":"string","description":"First day, YYYY-MM-DD. Defaults to 29 days before end_date."},"end_date":{"type":"string","description":"Last day, YYYY-MM-DD. Defaults to today."},"product_id":{"type":"string","description":"Only this product (id from list_products)."},"breakdown":{"type":"string","enum":["product","country","day","week","month"],"description":"product (default), country, day, week or month. A period row's date is the day, the Monday of the week, or the first of the month, in the creator's time zone."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"list_payouts","title":"List payouts","description":"Recent payouts to the creator's bank or PayPal.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Max payouts to return (1-50, default 10)."},"cursor":{"type":"string","description":"next_cursor from the previous page."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":true,"destructiveHint":false}},{"name":"create_bundle","title":"Create bundle","description":"Create a draft bundle: one product that sells several of the creator's own products together at the bundle's own price. It is not for sale until publish_product runs. Confirm the products and the price with the creator first.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Bundle name."},"price_cents":{"type":"integer","description":"Price of the bundle in minor units (cents for USD). It is not derived from the products it contains; use 0 for a free bundle."},"product_ids":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Ids or permalinks of the creator's products the bundle sells, in the order they should appear. A product sold in versions is added at its first version."}},"additionalProperties":false,"required":["name","price_cents","product_ids"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":false}},{"name":"update_bundle","title":"Update bundle","description":"Replace the products a bundle sells. The bundle keeps its name, price, description, and published state; use update_product for the name, price, or description, and publish_product or unpublish_product for its state. Confirm the new list with the creator first.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Bundle id or permalink."},"product_ids":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Ids or permalinks of the creator's products the bundle should sell, in the order they should appear. This list replaces the bundle's current products. A product the bundle already sells keeps its version and quantity."}},"additionalProperties":false,"required":["id","product_ids"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":true}},{"name":"create_discount_code","title":"Create discount code","description":"Create a discount code for all of the creator's products, or for one product. Pass exactly one of percent_off or amount_cents. Confirm the code, the amount, and which products it covers with the creator first, and call this once per confirmation: an existing code is refused, not duplicated.","inputSchema":{"type":"object","properties":{"code":{"type":"string","description":"The code buyers enter. Letters, numbers, dashes, and underscores."},"product_id":{"type":"string","description":"Product id or permalink. Omit for a code that covers all of the creator's products."},"percent_off":{"type":"integer","description":"Percent off, 1-100. Not with amount_cents."},"amount_cents":{"type":"integer","description":"Fixed amount off in minor units of the product's currency (the creator's currency for an all-products code). Not with percent_off."},"valid_at":{"type":"string","description":"ISO 8601 time the code starts working. If only expires_at is given, the start is now for a new code and unchanged for an existing one."},"expires_at":{"type":"string","description":"ISO 8601 time the code stops working."},"max_purchase_count":{"type":"integer","description":"How many times the code can be used in total. 0 or more."}},"additionalProperties":false,"required":["code"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":false}},{"name":"update_discount_code","title":"Update discount code","description":"Change the amount, dates, or usage limit of an existing discount code. Pass only the fields to change. A code that covers several products changes for all of them. Confirm the changes with the creator first.","inputSchema":{"type":"object","properties":{"code":{"type":"string","description":"The existing code."},"product_id":{"type":"string","description":"Product id or permalink, for a code made for specific products. Omit for a code that covers all products."},"percent_off":{"type":"integer","description":"Percent off, 1-100. Not with amount_cents."},"amount_cents":{"type":"integer","description":"Fixed amount off in minor units of the product's currency (the creator's currency for an all-products code). Not with percent_off."},"valid_at":{"type":"string","description":"ISO 8601 time the code starts working. If only expires_at is given, the start is now for a new code and unchanged for an existing one."},"expires_at":{"type":"string","description":"ISO 8601 time the code stops working."},"max_purchase_count":{"type":"integer","description":"How many times the code can be used in total. 0 or more."}},"additionalProperties":false,"required":["code"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":true}},{"name":"expire_discount_code","title":"Expire discount code","description":"End a discount code now so buyers can no longer use it. The code is kept and shows as expired; update_discount_code with a later expires_at reopens it. Expiring a code that has already expired changes nothing and succeeds. Confirm with the creator first.","inputSchema":{"type":"object","properties":{"code":{"type":"string","description":"The existing code."},"product_id":{"type":"string","description":"Product id or permalink, for a code made for specific products. Omit for a code that covers all products."}},"additionalProperties":false,"required":["code"]},"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":true}}]}}
      JSON
    end

    %w[muse claude chatgpt].each do |client|
      it "keeps the legacy initialize bytes on #{client} while the revision is served" do
        post "/#{client}/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json, headers: undeclared_headers

        expect(response).to be_successful
        expect(response.body).to eq(legacy_initialize_body)
      end

      it "keeps the legacy initialize bytes on #{client} when only the version header is declared" do
        post "/#{client}/v1/mcp",
             params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
             headers: undeclared_headers.merge(Mcp::Server::VERSION_HEADER => Mcp::Server::LEGACY_PROTOCOL_VERSION)

        expect(response).to be_successful
        expect(response.body).to eq(legacy_initialize_body)
      end

      it "keeps the legacy tools/list bytes on #{client} while the revision is served" do
        post "/#{client}/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: undeclared_headers

        expect(response).to be_successful
        expect(response.body).to eq(legacy_tools_body)
      end
    end

    it "keeps the legacy bytes when the client declares the legacy revision explicitly" do
      post "/muse/v1/mcp",
           params: declared_request("initialize", version: Mcp::Server::LEGACY_PROTOCOL_VERSION).to_json,
           headers: undeclared_headers.merge(Mcp::Server::VERSION_HEADER => Mcp::Server::LEGACY_PROTOCOL_VERSION)

      expect(response).to be_successful
      expect(response.body).to eq(legacy_initialize_body)
    end

    it "treats a revision declared only in the header as undeclared" do
      post "/muse/v1/mcp",
           params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
           headers: undeclared_headers.merge(Mcp::Server::VERSION_HEADER => Mcp::Server::MODERN_PROTOCOL_VERSION)

      expect(response).to be_successful
      expect(response.body).to eq(legacy_initialize_body)
    end

    it "serves server/discover" do
      post_declared(declared_request("server/discover"))

      expect(response).to be_successful
      result = response.parsed_body["result"]
      expect(result["supportedVersions"]).to eq(["2025-03-26", "2026-07-28"])
      expect(result["resultType"]).to eq("complete")
      expect(result["capabilities"]).to eq({ "tools" => { "listChanged" => false } })
      expect(result["_meta"]).to eq("io.modelcontextprotocol/serverInfo" => { "name" => "gumroad", "title" => "Gumroad", "version" => "1.0.0" })
      expect(result["instructions"]).to include("check out on the product URL")
    end

    it "adds the modern envelope to tools/list without changing the tools" do
      post_declared(declared_request("tools/list"))

      result = response.parsed_body["result"]
      expect(result["resultType"]).to eq("complete")
      expect(result["ttlMs"]).to eq(0)
      expect(result["cacheScope"]).to eq("private")
      expect(result["tools"].map { _1["name"] }).to include("get_account", "list_sales")
      expect(result["tools"].first.keys).to contain_exactly("name", "title", "description", "inputSchema", "annotations")
    end

    it "serves a tool call that repeats its name in the header" do
      create(:purchase, seller: @seller, link: @product, email: "modern@example.com", price_cents: 1900)

      post_declared(declared_request("tools/call", name: "list_sales", arguments: {}), headers: { Mcp::Server::NAME_HEADER => "list_sales" })

      expect(response).to be_successful
      result = response.parsed_body["result"]
      expect(result["resultType"]).to eq("complete")
      expect(result["structuredContent"]["sales"].map { _1["email"] }).to eq(["modern@example.com"])
    end

    it "tells a modern client that the removed handshake and ping do not exist" do
      %w[initialize ping].each do |method|
        post_declared(declared_request(method))

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["error"]).to include("code" => -32601, "message" => "Method not found: #{method}")
      end
    end

    it "accepts a modern notification without a response body" do
      post_declared(declared_request("notifications/initialized").except(:id))

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    it "rejects a version the header and _meta disagree about" do
      post_declared(declared_request("server/discover"), declared: Mcp::Server::LEGACY_PROTOCOL_VERSION)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
      expect(response.parsed_body["error"]["data"]).to include("header" => "2025-03-26", "declared" => "2026-07-28")
    end

    it "rejects a version declared only in _meta" do
      post_declared(declared_request("server/discover"), headers: { Mcp::Server::VERSION_HEADER => nil })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
    end

    it "rejects a modern request without the method header" do
      post_declared(declared_request("server/discover"), headers: { Mcp::Server::METHOD_HEADER => nil })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
    end

    it "rejects a modern tool call whose name header does not match" do
      post_declared(declared_request("tools/call", name: "list_sales", arguments: {}), headers: { Mcp::Server::NAME_HEADER => "list_payouts" })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
      expect(response.parsed_body["error"]["data"]).to include("header" => "list_payouts", "name" => "list_sales")
    end

    it "rejects a modern tool call with no name header and no name" do
      post_declared(declared_request("tools/call", arguments: {}), headers: { Mcp::Server::NAME_HEADER => nil })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
    end

    it "answers a revision it does not serve with the ones it does" do
      post_declared(declared_request("server/discover", version: "2025-11-25"), declared: "2025-11-25")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32022, "data" => { "supported" => ["2025-03-26", "2026-07-28"], "requested" => "2025-11-25" })
    end

    it "keeps the revision unsupported until the flag is on" do
      Feature.deactivate(:mcp_protocol_2026_07_28)

      post_declared(declared_request("server/discover"))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]["code"]).to eq(-32022)
      expect(response.parsed_body["error"]["data"]["supported"]).to eq(["2025-03-26"])
    end
  end

  context "with a client declaring the 2026-07-28 revision in params._meta" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
      Feature.activate(:mcp_protocol_2026_07_28)
    end

    # The request shape the 2026-07-28 schema specifies: the declaration lives in params._meta.
    def canonical_request(method, version: Mcp::Server::MODERN_PROTOCOL_VERSION, **params)
      meta = {
        Mcp::Server::VERSION_META_KEY => version,
        "io.modelcontextprotocol/clientInfo" => { "name" => "spec-client", "version" => "1.0.0" },
        "io.modelcontextprotocol/clientCapabilities" => {}
      }
      { jsonrpc: "2.0", id: 1, method:, params: params.merge(_meta: meta) }
    end

    def post_canonical(client, payload, headers: {}, declared: Mcp::Server::MODERN_PROTOCOL_VERSION)
      post "/#{client}/v1/mcp", params: payload.to_json, headers: {
        "CONTENT_TYPE" => "application/json",
        "HOST" => DOMAIN,
        "Authorization" => "Bearer #{@token.token}",
        Mcp::Server::VERSION_HEADER => declared,
        Mcp::Server::METHOD_HEADER => payload[:method].to_s
      }.merge(headers).compact
    end

    def get_account_call = canonical_request("tools/call", name: "get_account", arguments: {})

    %w[muse claude chatgpt].each do |client|
      it "serves server/discover with its cache fields on #{client}" do
        post_canonical(client, canonical_request("server/discover"))

        expect(response).to have_http_status(:ok)
        result = response.parsed_body["result"]
        expect(result).to include(
          "supportedVersions" => ["2025-03-26", "2026-07-28"],
          "capabilities" => { "tools" => { "listChanged" => false } },
          "resultType" => "complete",
          "ttlMs" => 0,
          "cacheScope" => "public"
        )
        expect(result["_meta"]).to eq("io.modelcontextprotocol/serverInfo" => { "name" => "gumroad", "title" => "Gumroad", "version" => "1.0.0" })
      end

      it "serves tools/call get_account on the modern lane on #{client}" do
        post_canonical(client, get_account_call, headers: { Mcp::Server::NAME_HEADER => "get_account" })

        expect(response).to have_http_status(:ok)
        result = response.parsed_body["result"]
        expect(result["resultType"]).to eq("complete")
        expect(result["structuredContent"]).to include("id" => @seller.external_id, "username" => @seller.username)
      end

      it "answers tools/call with -32022 rather than the legacy lane while the flag is off on #{client}" do
        Feature.deactivate(:mcp_protocol_2026_07_28)

        post_canonical(client, get_account_call, headers: { Mcp::Server::NAME_HEADER => "get_account" })

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).not_to have_key("result")
        expect(response.parsed_body["error"]).to include(
          "code" => -32022,
          "data" => { "supported" => ["2025-03-26"], "requested" => "2026-07-28" }
        )
      end

      it "counts the declaration under its revision on #{client}, with the flag off and on" do
        post_canonical(client, canonical_request("server/discover"))
        Feature.deactivate(:mcp_protocol_2026_07_28)
        post_canonical(client, get_account_call, headers: { Mcp::Server::NAME_HEADER => "get_account" })

        expect(Mcp::ProtocolTelemetry.mix[client]).to eq("2026-07-28" => { "server/discover" => 1, "tools/call" => 1 })
      end
    end

    it "answers server/discover with -32022 while the flag is off" do
      Feature.deactivate(:mcp_protocol_2026_07_28)

      post_canonical("muse", canonical_request("server/discover"))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32022, "data" => { "supported" => ["2025-03-26"], "requested" => "2026-07-28" })
    end

    it "rejects a declaration the version header disagrees with" do
      post_canonical("muse", canonical_request("server/discover"), declared: Mcp::Server::LEGACY_PROTOCOL_VERSION)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
      expect(response.parsed_body["error"]["data"]).to include("header" => "2025-03-26", "declared" => "2026-07-28")
    end

    it "rejects a declaration with no version header" do
      post_canonical("muse", canonical_request("server/discover"), headers: { Mcp::Server::VERSION_HEADER => nil })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
    end

    it "rejects a tool call whose name header does not match" do
      post_canonical("muse", get_account_call, headers: { Mcp::Server::NAME_HEADER => "list_sales" })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
      expect(response.parsed_body["error"]["data"]).to include("header" => "list_sales", "name" => "get_account")
    end

    it "answers a revision it does not serve with the ones it does" do
      post_canonical("muse", canonical_request("server/discover", version: "2025-11-25"), declared: "2025-11-25")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32022, "data" => { "supported" => ["2025-03-26", "2026-07-28"], "requested" => "2025-11-25" })
    end

    it "serves a request that declares the same revision in params._meta and at the top level" do
      post_canonical("muse", canonical_request("server/discover").merge(_meta: { Mcp::Server::VERSION_META_KEY => Mcp::Server::MODERN_PROTOCOL_VERSION }))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]["resultType"]).to eq("complete")
    end

    it "rejects a request whose params._meta and top-level _meta declare different revisions" do
      payload = get_account_call.merge(_meta: { Mcp::Server::VERSION_META_KEY => Mcp::Server::LEGACY_PROTOCOL_VERSION })

      post_canonical("muse", payload, headers: { Mcp::Server::NAME_HEADER => "get_account" })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).not_to have_key("result")
      expect(response.parsed_body["error"]).to include("code" => -32020, "data" => { "declared" => "2026-07-28", "top_level" => "2025-03-26" })
    end

    it "keeps the legacy bytes when params._meta carries no usable declaration" do
      headers = { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}" }
      # The undeclared bytes are pinned to the golden fixture by the 2026-07-28 context above.
      post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: headers
      undeclared = response.body

      [{ _meta: "2026-07-28" }, { _meta: { Mcp::Server::VERSION_META_KEY => "" } }, { _meta: { "progressToken" => 7 } }].each do |params|
        post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list", params: }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq(undeclared)
      end
      expect(Mcp::ProtocolTelemetry.mix["muse"]).to eq("undeclared" => { "tools/list" => 4 })
    end
  end

  describe "revision telemetry" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
      Feature.deactivate(:mcp_protocol_2026_07_28)
    end

    def post_mcp_on(client, payload, headers: {})
      post "/#{client}/v1/mcp", params: payload.to_json, headers: {
        "CONTENT_TYPE" => "application/json",
        "HOST" => DOMAIN,
        "Authorization" => "Bearer #{@token.token}"
      }.merge(headers)
    end

    def declaring(version, method: "tools/list")
      {
        jsonrpc: "2.0",
        id: 1,
        method:,
        _meta: { Mcp::Server::VERSION_META_KEY => version },
      }
    end

    def declare(version)
      { Mcp::Server::VERSION_HEADER => version }
    end

    def counter_key = RedisKey.mcp_protocol_requests(Date.current)

    # The commands touching the day's counters while the block runs, from whichever client sends
    # them. `fail_after:` drops the connection on every such command after that many.
    def counter_commands(fail_after: nil)
      commands = []
      watching = true
      allow_any_instance_of(Redis::Client).to receive(:call_v).and_wrap_original do |original, command, &block|
        if watching && command.include?(counter_key)
          commands << command.first.to_s.downcase
          raise RedisClient::ConnectionError, "connection lost" if fail_after && commands.size > fail_after
        end
        original.call(command, &block)
      end
      yield
      watching = false
      commands
    end

    it "counts an undeclared caller apart from one that declares a revision, on every connector path" do
      %w[muse claude chatgpt].each do |client|
        post_mcp_on(client, { jsonrpc: "2.0", id: 1, method: "tools/list" })
        post_mcp_on(client, declaring(Mcp::Server::LEGACY_PROTOCOL_VERSION), headers: declare(Mcp::Server::LEGACY_PROTOCOL_VERSION))
        post_mcp_on(client, declaring(Mcp::Server::MODERN_PROTOCOL_VERSION), headers: declare(Mcp::Server::MODERN_PROTOCOL_VERSION))
      end

      mix = Mcp::ProtocolTelemetry.mix
      expect(mix.keys).to contain_exactly("muse", "claude", "chatgpt")
      expect(mix.values).to all(eq(
        "undeclared" => { "tools/list" => 1 },
        "2025-03-26" => { "tools/list" => 1 },
        "2026-07-28" => { "tools/list" => 1 }
      ))
    end

    it "counts each message of a batch" do
      post_mcp_on("muse", [
                    { jsonrpc: "2.0", id: 1, method: "tools/list" },
                    { jsonrpc: "2.0", id: 2, method: "tools/list" },
                  ])

      expect(Mcp::ProtocolTelemetry.mix["muse"]).to eq("undeclared" => { "tools/list" => 2 })
    end

    it "counts no caller identity" do
      post_mcp_on("muse", { jsonrpc: "2.0", id: 1, method: "tools/list" })

      expect($redis.hgetall(RedisKey.mcp_protocol_requests(Date.current)).keys).to eq(["muse|undeclared|tools/list"])
    end

    it "names only an exact known revision and buckets every other declaration and method" do
      ["2025-06-18", "2099-01-01", " 2026-07-28", "2026-07-28 ", "not-a-version"].each do |version|
        post_mcp_on("muse", declaring(version), headers: declare(version))
      end
      post_mcp_on("muse", { jsonrpc: "2.0", id: 1, method: "prompts/list" })

      expect(Mcp::ProtocolTelemetry.mix["muse"]).to eq(
        "2025-06-18" => { "tools/list" => 1 },
        "other" => { "tools/list" => 4 },
        "undeclared" => { "other" => 1 }
      )
    end

    it "stores no client-supplied value and keeps every count, however many distinct values a batch sends" do
      adversarial = Array.new(1000) do |index|
        { jsonrpc: "2.0", id: index, method: "tools/call/#{index}", _meta: { Mcp::Server::VERSION_META_KEY => (Date.new(2100, 1, 1) + index).iso8601 } }
      end
      known = [
        { jsonrpc: "2.0", id: 1000, method: "tools/list" },
        declaring(Mcp::Server::LEGACY_PROTOCOL_VERSION).merge(id: 1001),
      ]

      post_mcp_on("muse", adversarial + known, headers: declare(Mcp::Server::LEGACY_PROTOCOL_VERSION))

      expect($redis.hgetall(counter_key)).to eq(
        "muse|other|other" => "1000",
        "muse|undeclared|tools/list" => "1",
        "muse|2025-03-26|tools/list" => "1"
      )
    end

    it "writes a batch's counters and their retention in one command" do
      commands = counter_commands do
        post_mcp_on("muse", Array.new(3) { |index| { jsonrpc: "2.0", id: index, method: "tools/list" } })
      end

      expect(commands).to eq(["eval"])
      expect(Mcp::ProtocolTelemetry.mix["muse"]).to eq("undeclared" => { "tools/list" => 3 })
      expect($redis.ttl(counter_key)).to be_within(5).of(Mcp::ProtocolTelemetry::RETENTION.to_i)
    end

    it "never leaves a counted day without its retention when the connection drops after the first write" do
      counter_commands(fail_after: 1) { post_mcp_on("muse", { jsonrpc: "2.0", id: 1, method: "tools/list" }) }

      expect(response).to be_successful
      expect($redis.hgetall(counter_key)).to eq("muse|undeclared|tools/list" => "1")
      expect($redis.ttl(counter_key)).to be_within(5).of(Mcp::ProtocolTelemetry::RETENTION.to_i)
    end

    it "restores the retention of a day that already has counts but lost its expiry" do
      $redis.hset(counter_key, "muse|undeclared|tools/list", 1)

      post_mcp_on("muse", { jsonrpc: "2.0", id: 1, method: "tools/list" })

      expect($redis.hgetall(counter_key)).to eq("muse|undeclared|tools/list" => "2")
      expect($redis.ttl(counter_key)).to be_within(5).of(Mcp::ProtocolTelemetry::RETENTION.to_i)
    end

    it "serves the same response when the counter cannot be written, with one class-only warning" do
      warnings = []
      allow(Rails.logger).to receive(:warn).and_wrap_original do |original, *args, &block|
        warnings << args.first
        original.call(*args, &block)
      end
      batch = Array.new(2) { |index| { jsonrpc: "2.0", id: index, method: "tools/list" } }

      counter_commands(fail_after: 0) { post_mcp_on("muse", batch) }
      failed = response

      expect(failed).to be_successful
      expect(warnings.grep(/mcp_protocol_telemetry/)).to eq(["mcp_protocol_telemetry_failed Redis::ConnectionError"])
      post_mcp_on("muse", batch)
      expect(failed.body).to eq(response.body)
    end

    it "counts the connector from the route, whatever the request claims" do
      post "/muse/v1/mcp?client=claude", params: { jsonrpc: "2.0", id: 1, method: "tools/list", client: "chatgpt" }.to_json, headers: {
        "CONTENT_TYPE" => "application/json",
        "HOST" => DOMAIN,
        "Authorization" => "Bearer #{@token.token}"
      }

      expect(Mcp::ProtocolTelemetry.mix.keys).to eq(["muse"])
    end

    it "counts no unauthenticated request" do
      post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
                           headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN }

      expect(response).to have_http_status(:unauthorized)
      expect($redis.hgetall(RedisKey.mcp_protocol_requests(Date.current))).to be_empty
    end
  end

  context "discount code tools" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "edit_products")
    end

    def call_tool(name, arguments)
      post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } })
    end

    def tool_result = response.parsed_body["result"]

    it "creates a universal percent code" do
      expect { call_tool("create_discount_code", { code: "SPRING20", percent_off: 20 }) }.to change(OfferCode, :count).by(1)

      offer_code = @seller.offer_codes.last
      expect(offer_code).to have_attributes(code: "SPRING20", universal: true, link_id: nil, amount_percentage: 20, amount_cents: nil)
      expect(offer_code.products).to be_empty
      expect(tool_result["structuredContent"]["discount_code"]).to include(
        "id" => offer_code.external_id, "code" => "SPRING20", "scope" => "universal", "product_ids" => [],
        "percent_off" => 20, "amount_cents" => nil, "expires_at" => nil, "expired" => false
      )
    end

    it "creates a code bound to one of the seller's products" do
      other_product = create(:product, user: @seller, price_cents: 1900)

      call_tool("create_discount_code", { code: "NOTES5", product_id: @product.unique_permalink, amount_cents: 500, max_purchase_count: 10, valid_at: "2026-01-01T00:00:00Z", expires_at: "2099-01-01T00:00:00Z" })

      offer_code = @seller.offer_codes.find_by!(code: "NOTES5")
      expect(offer_code.universal).to eq(false)
      expect(offer_code.products).to eq([@product])
      expect(offer_code.applicable?(other_product)).to eq(false)
      expect(offer_code).to have_attributes(amount_cents: 500, currency_type: "usd", max_purchase_count: 10, valid_at: Time.utc(2026, 1, 1), expires_at: Time.utc(2099, 1, 1))
      expect(tool_result["structuredContent"]["discount_code"]).to include("scope" => @product.external_id, "product_ids" => [@product.external_id], "amount_cents" => 500, "currency" => "usd")
    end

    it "rejects an amount that breaks the minimum-price rule with the editor's message" do
      expect { call_tool("create_discount_code", { code: "TOODEEP", product_id: @product.external_id, amount_cents: 1850 }) }.not_to change(OfferCode, :count)

      expect(tool_result["isError"]).to eq(true)
      expect(tool_result.dig("content", 0, "text")).to eq("The price after discount for all of your products must be either $0 or at least $0.99.")
    end

    it "refuses a code that already exists instead of creating a second one" do
      call_tool("create_discount_code", { code: "ONCE", percent_off: 10 })

      expect { call_tool("create_discount_code", { code: "ONCE", percent_off: 10 }) }.not_to change(OfferCode, :count)
      expect(tool_result["isError"]).to eq(true)
      expect(tool_result.dig("content", 0, "text")).to eq("Discount code must be unique.")

      expect { call_tool("create_discount_code", { code: "ONCE", product_id: @product.external_id, percent_off: 10 }) }.not_to change(OfferCode, :count)
      expect(tool_result.dig("content", 0, "text")).to eq("Discount code must be unique.")
    end

    it "requires exactly one of percent_off or amount_cents" do
      expect { call_tool("create_discount_code", { code: "BOTH", percent_off: 10, amount_cents: 100 }) }.not_to change(OfferCode, :count)
      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "Pass only one of percent_off or amount_cents")

      expect { call_tool("create_discount_code", { code: "NEITHER" }) }.not_to change(OfferCode, :count)
      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "Pass one of percent_off or amount_cents")

      call_tool("create_discount_code", { code: "TOOMUCH", percent_off: 101 })
      expect(response.parsed_body["error"]).to include("code" => -32602)
    end

    it "refuses another seller's product and creates nothing" do
      other_product = create(:product, price_cents: 1900)

      expect { call_tool("create_discount_code", { code: "THEIRS", product_id: other_product.external_id, percent_off: 10 }) }.not_to change(OfferCode, :count)

      expect(tool_result.dig("content", 0, "text")).to eq("The product was not found.")
    end

    it "refuses an amount too large to store with the editor's message" do
      expect { call_tool("create_discount_code", { code: "HUGE", amount_cents: 3_000_000_000 }) }.not_to change(OfferCode, :count)
      expect(tool_result["isError"]).to eq(true)
      expect(tool_result.dig("content", 0, "text")).to eq("The value entered is too large. Please enter a smaller number.")

      offer_code = create(:universal_offer_code, user: @seller, code: "BIG")
      expect { call_tool("update_discount_code", { code: "BIG", amount_cents: 3_000_000_000 }) }.not_to change { offer_code.reload.attributes }
      expect(tool_result.dig("content", 0, "text")).to eq("The value entered is too large. Please enter a smaller number.")
    end

    it "rejects a malformed time" do
      expect { call_tool("create_discount_code", { code: "WHEN", percent_off: 10, expires_at: "next tuesday" }) }.not_to change(OfferCode, :count)

      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "expires_at must be an ISO 8601 time")
    end

    it "rejects a year the database would store as an empty date" do
      expect { call_tool("create_discount_code", { code: "FAR", percent_off: 10, valid_at: "20271-01-01T00:00:00Z" }) }.not_to change(OfferCode, :count)
      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "valid_at must have a year from 1000 to 9999")

      offer_code = create(:universal_offer_code, user: @seller, code: "PAUSED", valid_at: 1.week.from_now)
      expect { call_tool("update_discount_code", { code: "PAUSED", expires_at: "+10000-01-01T00:00:00Z" }) }.not_to change { offer_code.reload.attributes }
      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "expires_at must have a year from 1000 to 9999")
    end

    it "rejects a blank code and a negative usage limit" do
      expect { call_tool("create_discount_code", { code: "  ", percent_off: 10 }) }.not_to change(OfferCode, :count)
      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "code is required")

      expect { call_tool("create_discount_code", { code: "NEG", percent_off: 10, max_purchase_count: -1 }) }.not_to change(OfferCode, :count)
      expect(response.parsed_body["error"]).to include("code" => -32602, "message" => "max_purchase_count must be zero or more")
    end

    it "ignores another seller's code attached to the caller's product" do
      foreign_code = create(:offer_code, code: "STRAY", amount_cents: 100, products: [@product])
      foreign_code.update_column(:user_id, create(:user).id)

      call_tool("expire_discount_code", { code: "STRAY", product_id: @product.external_id })

      expect(tool_result.dig("content", 0, "text")).to include("No discount code STRAY is limited to this product")
      expect(foreign_code.reload.expires_at).to be_nil
    end

    it "refuses to update or expire a code through another seller's product" do
      other_code = create(:offer_code, code: "THEIRS", amount_cents: 100)
      other_product = other_code.products.first

      call_tool("update_discount_code", { code: "THEIRS", product_id: other_product.external_id, amount_cents: 50 })
      expect(tool_result.dig("content", 0, "text")).to eq("The product was not found.")
      call_tool("expire_discount_code", { code: "THEIRS", product_id: other_product.external_id })
      expect(tool_result.dig("content", 0, "text")).to eq("The product was not found.")
      expect(other_code.reload).to have_attributes(amount_cents: 100, expires_at: nil)
    end

    it "keeps the start date when an update only sets expires_at" do
      offer_code = create(:universal_offer_code, user: @seller, code: "LATER")

      call_tool("update_discount_code", { code: "LATER", expires_at: "2099-01-01T00:00:00Z" })

      expect(offer_code.reload).to have_attributes(valid_at: offer_code.created_at, expires_at: Time.utc(2099, 1, 1))
    end

    it "expires a code scheduled to start in the future" do
      offer_code = create(:universal_offer_code, user: @seller, code: "SOON", valid_at: 1.week.from_now, expires_at: 2.weeks.from_now)

      call_tool("expire_discount_code", { code: "SOON" })

      expect(offer_code.reload.expires_at).to be <= Time.current
      expect(offer_code.valid_at).to be < offer_code.expires_at
    end

    it "expires a code the current prices would refuse to save" do
      offer_code = create(:universal_offer_code, user: @seller, code: "HALF", amount_cents: nil, amount_percentage: 50)
      create(:product, user: @seller, price_cents: 100)
      expect(offer_code.reload).not_to be_valid

      call_tool("expire_discount_code", { code: "HALF" })

      expect(offer_code.reload.expires_at).to be <= Time.current
      expect(offer_code).to be_inactive
      expect(tool_result["structuredContent"]["discount_code"]).to include("expired" => true)
    end

    it "refuses to address another seller's code" do
      other_code = create(:universal_offer_code, code: "SHARED", amount_cents: nil, amount_percentage: 10)

      expect { call_tool("update_discount_code", { code: "SHARED", percent_off: 50 }) }.not_to change { other_code.reload.attributes }
      expect(tool_result["isError"]).to eq(true)
    end

    it "changes only the supplied field and keeps the minimum-price rule" do
      offer_code = create(:offer_code, user: @seller, products: [@product], code: "EDITME", amount_cents: 500, max_purchase_count: 7)

      call_tool("update_discount_code", { code: "EDITME", product_id: @product.external_id, amount_cents: 600 })

      expect(tool_result["structuredContent"]["discount_code"]).to include("amount_cents" => 600)
      expect(offer_code.reload).to have_attributes(amount_cents: 600, amount_percentage: nil, max_purchase_count: 7, code: "EDITME", expires_at: nil)
      expect(offer_code.products).to eq([@product])

      expect { call_tool("update_discount_code", { code: "EDITME", product_id: @product.external_id, amount_cents: 1850 }) }.not_to change { offer_code.reload.attributes }
      expect(tool_result["isError"]).to eq(true)
      expect(tool_result.dig("content", 0, "text")).to include("must be either $0 or at least")
    end

    it "switches a code from a fixed amount to a percentage" do
      offer_code = create(:offer_code, user: @seller, products: [@product], code: "SWITCH", amount_cents: 500)

      call_tool("update_discount_code", { code: "SWITCH", product_id: @product.external_id, percent_off: 25 })

      expect(offer_code.reload).to have_attributes(amount_percentage: 25, amount_cents: nil, currency_type: nil)
    end

    it "refuses an amount change on a tiered code but still edits its other fields" do
      offer_code = create(:tiered_offer_code, user: @seller, products: [@product], code: "LOYAL",
                                              ownership_duration_tiers: [{ "months" => 0, "amount_percentage" => 10 }, { "months" => 12, "amount_percentage" => 50 }])

      expect { call_tool("update_discount_code", { code: "LOYAL", product_id: @product.external_id, percent_off: 30 }) }.not_to change { offer_code.reload.attributes }
      expect(tool_result["isError"]).to eq(true)
      expect(tool_result.dig("content", 0, "text")).to include("Change its amounts in the Gumroad dashboard")

      call_tool("update_discount_code", { code: "LOYAL", product_id: @product.external_id, max_purchase_count: 5 })
      expect(tool_result["structuredContent"]["discount_code"]).to include("percent_off" => nil, "tiers" => [{ "months" => 0, "amount_percentage" => 10 }, { "months" => 12, "amount_percentage" => 50 }])
      expect(offer_code.reload).to have_attributes(max_purchase_count: 5, ownership_duration_tiers: [{ "months" => 0, "amount_percentage" => 10 }, { "months" => 12, "amount_percentage" => 50 }])
    end

    it "needs product_id to find a product-specific code" do
      create(:offer_code, user: @seller, products: [@product], code: "SCOPED", amount_cents: 500)

      call_tool("update_discount_code", { code: "SCOPED", amount_cents: 600 })

      expect(tool_result["isError"]).to eq(true)
      expect(tool_result.dig("content", 0, "text")).to include("Pass product_id")
    end

    it "rejects an update with nothing to change" do
      create(:universal_offer_code, user: @seller, code: "NOOP")

      call_tool("update_discount_code", { code: "NOOP" })

      expect(response.parsed_body["error"]).to include("code" => -32602)
    end

    it "expires a code by ending its validity, and a second expire succeeds without changes" do
      offer_code = create(:universal_offer_code, user: @seller, code: "ENDNOW", amount_cents: nil, amount_percentage: 10)

      call_tool("expire_discount_code", { code: "ENDNOW" })

      expect(tool_result["structuredContent"]["discount_code"]).to include("expired" => true)
      offer_code.reload
      expect(offer_code.deleted_at).to be_nil
      expect(offer_code.expires_at).to be <= Time.current
      expect(offer_code).to be_inactive

      expect { call_tool("expire_discount_code", { code: "ENDNOW" }) }.not_to change { offer_code.reload.attributes }
      expect(tool_result).not_to have_key("isError")
      expect(tool_result["structuredContent"]).to include("message" => "Already expired.")
      expect(tool_result["structuredContent"]["discount_code"]).to include("expired" => true)
    end

    it "expires a product-specific code" do
      offer_code = create(:offer_code, user: @seller, products: [@product], code: "PRODEND", amount_cents: 500)

      call_tool("expire_discount_code", { code: "PRODEND", product_id: @product.external_id })

      expect(offer_code.reload).to be_inactive
    end

    it "refuses the discount tools with the same 403 challenge as the other write tools" do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_public")
      offer_code = create(:universal_offer_code, user: @seller, code: "LOCKED")

      expect { call_tool("create_discount_code", { code: "NOPE", percent_off: 10 }) }.not_to change(OfferCode, :count)
      expect(response).to have_http_status(:forbidden)
      expect(response.headers["WWW-Authenticate"]).to eq(
        %(Bearer realm="Gumroad", error="insufficient_scope", scope="view_public edit_products", ) +
        %(resource_metadata="#{PROTOCOL}://#{DOMAIN}/.well-known/oauth-protected-resource/muse/v1/mcp", ) +
        %(error_description="This tool requires the edit_products or account scope.")
      )

      %w[update_discount_code expire_discount_code].each do |name|
        expect { call_tool(name, { code: "LOCKED", **(name == "update_discount_code" ? { percent_off: 10 } : {}) }) }.not_to change { offer_code.reload.attributes }
        expect(response).to have_http_status(:forbidden)
        expect(response.headers["WWW-Authenticate"]).to include(%(error="insufficient_scope", scope="view_public edit_products"))
      end
    end
  end
end
