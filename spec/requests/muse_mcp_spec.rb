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
    expect(body["oauth"]["scopes"]).to match_array(Muse::OauthClientRegistration::MCP_SCOPES)
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
    expect(response.parsed_body["scopes_supported"]).to match_array(Muse::OauthClientRegistration::MCP_SCOPES)

    get "/.well-known/oauth-protected-resource/claude/v1/mcp", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    expect(response.parsed_body["resource"]).to eq("#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp")
    expect(response.parsed_body["scopes_supported"]).to match_array(Muse::OauthClientRegistration::MCP_SCOPES)
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
    expect(body["scopes_supported"]).to match_array(Muse::OauthClientRegistration::MCP_SCOPES)
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
    expect(response.parsed_body.fetch("scope").split).to match_array(Muse::OauthClientRegistration::MCP_SCOPES)

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
    expect(full_token.fetch("scope").split).to match_array(Muse::OauthClientRegistration::MCP_SCOPES)
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
        "publish_product" => "Publish product",
        "unpublish_product" => "Unpublish product",
        "list_sales" => "List sales",
        "list_payouts" => "List payouts"
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

    it "labels reads, drafts, and sale-state changes for the host" do
      post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" })

      annotations = response.parsed_body.dig("result", "tools").to_h { |tool| [tool["name"], tool["annotations"]] }
      expect(annotations.keys).to contain_exactly(
        "get_account", "list_products", "get_product", "create_draft_product",
        "publish_product", "unpublish_product", "list_sales", "list_payouts"
      )
      expect(annotations.values).to all(include("openWorldHint" => false))
      %w[get_account list_products get_product list_sales list_payouts].each do |name|
        expect(annotations[name]).to include("readOnlyHint" => true, "destructiveHint" => false)
      end
      expect(annotations["create_draft_product"]).to include("readOnlyHint" => false, "destructiveHint" => false)
      %w[publish_product unpublish_product].each do |name|
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

      expect(response).to have_http_status(:ok)
      expect(response.headers["WWW-Authenticate"]).to be_nil
      payload = response.parsed_body.dig("result", "structuredContent", "product")
      expect(payload["name"]).to eq("Muse draft")
      expect(payload["published"]).to eq(false)
      product = @seller.links.find_by_external_id(payload["id"])
      expect(product).to be_draft
      expect(product.purchase_disabled_at).to be_present
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

    def declared_request(method, version: Muse::Mcp::MODERN_PROTOCOL_VERSION, **params)
      request = { jsonrpc: "2.0", id: 1, method: method, _meta: { Muse::Mcp::VERSION_META_KEY => version } }
      request[:params] = params if params.any?
      request
    end

    def post_declared(payload, headers: {}, declared: Muse::Mcp::MODERN_PROTOCOL_VERSION)
      post "/muse/v1/mcp", params: payload.to_json, headers: {
        "CONTENT_TYPE" => "application/json",
        "HOST" => DOMAIN,
        "Authorization" => "Bearer #{@token.token}",
        Muse::Mcp::VERSION_HEADER => declared,
        Muse::Mcp::METHOD_HEADER => payload[:method].to_s
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
        {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"get_account","title":"Get account","description":"The connected creator's public profile: name, username, storefront URL, currency.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":false,"destructiveHint":false}},{"name":"list_products","title":"List products","description":"List the creator's products (newest first). Returns id, name, price, published state, and URL.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Max products to return (1-50, default 25)."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":false,"destructiveHint":false}},{"name":"get_product","title":"Get product","description":"Fetch one product by id or permalink.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":true,"openWorldHint":false,"destructiveHint":false}},{"name":"create_draft_product","title":"Create draft product","description":"Create a draft digital product. It is not for sale until publish_product runs. Confirm the name and price with the creator first.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Product name."},"price_cents":{"type":"integer","description":"Price in minor units (cents for USD). Use 0 for a free product."},"description":{"type":"string","description":"HTML or plain-text description."}},"additionalProperties":false,"required":["name","price_cents"]},"annotations":{"readOnlyHint":false,"openWorldHint":false,"destructiveHint":false}},{"name":"publish_product","title":"Publish product","description":"Make a draft product purchasable. Confirm with the creator first.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":false,"openWorldHint":false,"destructiveHint":true}},{"name":"unpublish_product","title":"Unpublish product","description":"Take a product off sale without deleting it.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"Product id or permalink."}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":false,"openWorldHint":false,"destructiveHint":true}},{"name":"list_sales","title":"List sales","description":"Recent successful sales. Includes buyer email, product, amount, and time.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Max sales to return (1-50, default 25)."},"email":{"type":"string","description":"Filter by buyer email."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":false,"destructiveHint":false}},{"name":"list_payouts","title":"List payouts","description":"Recent payouts to the creator's bank or PayPal.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Max payouts to return (1-50, default 10)."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":false,"destructiveHint":false}}]}}
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
             headers: undeclared_headers.merge(Muse::Mcp::VERSION_HEADER => Muse::Mcp::LEGACY_PROTOCOL_VERSION)

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
           params: declared_request("initialize", version: Muse::Mcp::LEGACY_PROTOCOL_VERSION).to_json,
           headers: undeclared_headers.merge(Muse::Mcp::VERSION_HEADER => Muse::Mcp::LEGACY_PROTOCOL_VERSION)

      expect(response).to be_successful
      expect(response.body).to eq(legacy_initialize_body)
    end

    it "treats a revision declared only in the header as undeclared" do
      post "/muse/v1/mcp",
           params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
           headers: undeclared_headers.merge(Muse::Mcp::VERSION_HEADER => Muse::Mcp::MODERN_PROTOCOL_VERSION)

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

      post_declared(declared_request("tools/call", name: "list_sales", arguments: {}), headers: { Muse::Mcp::NAME_HEADER => "list_sales" })

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
      post_declared(declared_request("server/discover"), declared: Muse::Mcp::LEGACY_PROTOCOL_VERSION)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
      expect(response.parsed_body["error"]["data"]).to include("header" => "2025-03-26", "declared" => "2026-07-28")
    end

    it "rejects a version declared only in _meta" do
      post_declared(declared_request("server/discover"), headers: { Muse::Mcp::VERSION_HEADER => nil })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
    end

    it "rejects a modern request without the method header" do
      post_declared(declared_request("server/discover"), headers: { Muse::Mcp::METHOD_HEADER => nil })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
    end

    it "rejects a modern tool call whose name header does not match" do
      post_declared(declared_request("tools/call", name: "list_sales", arguments: {}), headers: { Muse::Mcp::NAME_HEADER => "list_payouts" })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
      expect(response.parsed_body["error"]["data"]).to include("header" => "list_payouts", "name" => "list_sales")
    end

    it "rejects a modern tool call with no name header and no name" do
      post_declared(declared_request("tools/call", arguments: {}), headers: { Muse::Mcp::NAME_HEADER => nil })

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
    def canonical_request(method, version: Muse::Mcp::MODERN_PROTOCOL_VERSION, **params)
      meta = {
        Muse::Mcp::VERSION_META_KEY => version,
        "io.modelcontextprotocol/clientInfo" => { "name" => "spec-client", "version" => "1.0.0" },
        "io.modelcontextprotocol/clientCapabilities" => {}
      }
      { jsonrpc: "2.0", id: 1, method:, params: params.merge(_meta: meta) }
    end

    def post_canonical(client, payload, headers: {}, declared: Muse::Mcp::MODERN_PROTOCOL_VERSION)
      post "/#{client}/v1/mcp", params: payload.to_json, headers: {
        "CONTENT_TYPE" => "application/json",
        "HOST" => DOMAIN,
        "Authorization" => "Bearer #{@token.token}",
        Muse::Mcp::VERSION_HEADER => declared,
        Muse::Mcp::METHOD_HEADER => payload[:method].to_s
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
        post_canonical(client, get_account_call, headers: { Muse::Mcp::NAME_HEADER => "get_account" })

        expect(response).to have_http_status(:ok)
        result = response.parsed_body["result"]
        expect(result["resultType"]).to eq("complete")
        expect(result["structuredContent"]).to include("id" => @seller.external_id, "username" => @seller.username)
      end

      it "answers tools/call with -32022 rather than the legacy lane while the flag is off on #{client}" do
        Feature.deactivate(:mcp_protocol_2026_07_28)

        post_canonical(client, get_account_call, headers: { Muse::Mcp::NAME_HEADER => "get_account" })

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
        post_canonical(client, get_account_call, headers: { Muse::Mcp::NAME_HEADER => "get_account" })

        expect(Muse::ProtocolTelemetry.mix[client]).to eq("2026-07-28" => { "server/discover" => 1, "tools/call" => 1 })
      end
    end

    it "answers server/discover with -32022 while the flag is off" do
      Feature.deactivate(:mcp_protocol_2026_07_28)

      post_canonical("muse", canonical_request("server/discover"))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32022, "data" => { "supported" => ["2025-03-26"], "requested" => "2026-07-28" })
    end

    it "rejects a declaration the version header disagrees with" do
      post_canonical("muse", canonical_request("server/discover"), declared: Muse::Mcp::LEGACY_PROTOCOL_VERSION)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
      expect(response.parsed_body["error"]["data"]).to include("header" => "2025-03-26", "declared" => "2026-07-28")
    end

    it "rejects a declaration with no version header" do
      post_canonical("muse", canonical_request("server/discover"), headers: { Muse::Mcp::VERSION_HEADER => nil })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to include("code" => -32020)
    end

    it "rejects a tool call whose name header does not match" do
      post_canonical("muse", get_account_call, headers: { Muse::Mcp::NAME_HEADER => "list_sales" })

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
      post_canonical("muse", canonical_request("server/discover").merge(_meta: { Muse::Mcp::VERSION_META_KEY => Muse::Mcp::MODERN_PROTOCOL_VERSION }))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]["resultType"]).to eq("complete")
    end

    it "rejects a request whose params._meta and top-level _meta declare different revisions" do
      payload = get_account_call.merge(_meta: { Muse::Mcp::VERSION_META_KEY => Muse::Mcp::LEGACY_PROTOCOL_VERSION })

      post_canonical("muse", payload, headers: { Muse::Mcp::NAME_HEADER => "get_account" })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).not_to have_key("result")
      expect(response.parsed_body["error"]).to include("code" => -32020, "data" => { "declared" => "2026-07-28", "top_level" => "2025-03-26" })
    end

    it "keeps the legacy bytes when params._meta carries no usable declaration" do
      headers = { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}" }
      # The undeclared bytes are pinned to the golden fixture by the 2026-07-28 context above.
      post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: headers
      undeclared = response.body

      [{ _meta: "2026-07-28" }, { _meta: { Muse::Mcp::VERSION_META_KEY => "" } }, { _meta: { "progressToken" => 7 } }].each do |params|
        post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list", params: }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq(undeclared)
      end
      expect(Muse::ProtocolTelemetry.mix["muse"]).to eq("undeclared" => { "tools/list" => 4 })
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
        _meta: { Muse::Mcp::VERSION_META_KEY => version },
      }
    end

    def declare(version)
      { Muse::Mcp::VERSION_HEADER => version }
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
        post_mcp_on(client, declaring(Muse::Mcp::LEGACY_PROTOCOL_VERSION), headers: declare(Muse::Mcp::LEGACY_PROTOCOL_VERSION))
        post_mcp_on(client, declaring(Muse::Mcp::MODERN_PROTOCOL_VERSION), headers: declare(Muse::Mcp::MODERN_PROTOCOL_VERSION))
      end

      mix = Muse::ProtocolTelemetry.mix
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

      expect(Muse::ProtocolTelemetry.mix["muse"]).to eq("undeclared" => { "tools/list" => 2 })
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

      expect(Muse::ProtocolTelemetry.mix["muse"]).to eq(
        "2025-06-18" => { "tools/list" => 1 },
        "other" => { "tools/list" => 4 },
        "undeclared" => { "other" => 1 }
      )
    end

    it "stores no client-supplied value and keeps every count, however many distinct values a batch sends" do
      adversarial = Array.new(1000) do |index|
        { jsonrpc: "2.0", id: index, method: "tools/call/#{index}", _meta: { Muse::Mcp::VERSION_META_KEY => (Date.new(2100, 1, 1) + index).iso8601 } }
      end
      known = [
        { jsonrpc: "2.0", id: 1000, method: "tools/list" },
        declaring(Muse::Mcp::LEGACY_PROTOCOL_VERSION).merge(id: 1001),
      ]

      post_mcp_on("muse", adversarial + known, headers: declare(Muse::Mcp::LEGACY_PROTOCOL_VERSION))

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
      expect(Muse::ProtocolTelemetry.mix["muse"]).to eq("undeclared" => { "tools/list" => 3 })
      expect($redis.ttl(counter_key)).to be_within(5).of(Muse::ProtocolTelemetry::RETENTION.to_i)
    end

    it "never leaves a counted day without its retention when the connection drops after the first write" do
      counter_commands(fail_after: 1) { post_mcp_on("muse", { jsonrpc: "2.0", id: 1, method: "tools/list" }) }

      expect(response).to be_successful
      expect($redis.hgetall(counter_key)).to eq("muse|undeclared|tools/list" => "1")
      expect($redis.ttl(counter_key)).to be_within(5).of(Muse::ProtocolTelemetry::RETENTION.to_i)
    end

    it "restores the retention of a day that already has counts but lost its expiry" do
      $redis.hset(counter_key, "muse|undeclared|tools/list", 1)

      post_mcp_on("muse", { jsonrpc: "2.0", id: 1, method: "tools/list" })

      expect($redis.hgetall(counter_key)).to eq("muse|undeclared|tools/list" => "2")
      expect($redis.ttl(counter_key)).to be_within(5).of(Muse::ProtocolTelemetry::RETENTION.to_i)
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

      expect(Muse::ProtocolTelemetry.mix.keys).to eq(["muse"])
    end

    it "counts no unauthenticated request" do
      post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
                           headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN }

      expect(response).to have_http_status(:unauthorized)
      expect($redis.hgetall(RedisKey.mcp_protocol_requests(Date.current))).to be_empty
    end
  end
end
