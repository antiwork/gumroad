# frozen_string_literal: true

require "spec_helper"

describe "OAuth consent for an MCP client asking for a scope it did not register", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_user) }
  let(:resource) { Mcp::DynamicClientOauth.resource_identifier("/claude/v1/mcp") }
  let(:redirect_uri) { "https://claude.ai/api/mcp/auth_callback" }
  let(:code_verifier) { SecureRandom.urlsafe_base64(48) }
  let(:code_challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false) }
  # The scope list MCP clients registered with before view_library existed.
  let(:registered_scopes) { "view_public view_profile view_sales edit_products view_payouts" }
  let(:application) { register(registered_scopes) }

  before do
    host! DOMAIN
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
    Rails.application.reload_routes!
    sign_in user
  end

  # Through the real registration path, so the client is ownerless like every dynamic client.
  def register(scope)
    client = Mcp::OauthClientRegistration.create!("client_name" => "Claude", "redirect_uris" => [redirect_uri], "scope" => scope)
    OauthApplication.find_by!(uid: client[:client_id])
  end

  def authorize_params(scope:, client_id: application.uid)
    { response_type: "code", client_id:, redirect_uri:, scope:, state: "xyz", code_challenge:, code_challenge_method: "S256", resource: }
  end

  def consent_form_fields(params, method: nil)
    get "/claude/v1/oauth2/authorize", params: params
    expect(response).to have_http_status(:ok)
    form = Nokogiri::HTML(response.body).css("form").find { _1.at_css("input[name='_method']")&.[]("value") == method }
    form.css("input[type='hidden']").to_h { [_1["name"], _1["value"]] }
  end

  # Consents and exchanges the code, returning the token response.
  def connect(scope)
    post "/oauth/authorize", params: consent_form_fields(authorize_params(scope:))
    expect(response).to have_http_status(:found)
    code = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("code")

    post "/claude/v1/oauth2/token", params: { grant_type: "authorization_code", code:, redirect_uri:, client_id: application.uid, code_verifier:, resource: }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def list_purchases(access_token)
    post "/claude/v1/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_purchases", arguments: {} } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{access_token}" }
  end

  it "lets a client registered before view_library get it on consent, and the token reaches list_purchases" do
    consent_form_fields(authorize_params(scope: "view_public view_library"))
    expect(response.body).to include("See the products you bought.")

    token = connect("view_public view_library")
    expect(token.fetch("scope").split).to match_array(%w[view_public view_library])

    list_purchases(token.fetch("access_token"))
    expect(response).to have_http_status(:ok)
    expect(response.headers["WWW-Authenticate"]).to be_nil
    expect(response.parsed_body.dig("result", "structuredContent", "purchases")).to eq([])

    # Nothing is written to the client: the current policy is checked on every request.
    expect(application.reload.scopes.to_s).to eq(registered_scopes)
  end

  it "challenges a connected client's older token for view_library, so it can step up on consent" do
    old_token = connect("view_public view_sales")

    list_purchases(old_token.fetch("access_token"))
    expect(response).to have_http_status(:forbidden)
    expect(response.headers["WWW-Authenticate"]).to include(%(error="insufficient_scope", scope="view_public view_sales view_library"))

    stepped_up = connect("view_public view_sales view_library")
    list_purchases(stepped_up.fetch("access_token"))
    expect(response).to have_http_status(:ok)
  end

  it "lets a client registered with only the legacy account scope reconnect on the current scopes" do
    legacy = register("account")
    current = Mcp::OauthClientRegistration::MCP_SCOPES.join(" ")

    fields = consent_form_fields(authorize_params(scope: current, client_id: legacy.uid))
    post "/oauth/authorize", params: fields

    expect(response).to have_http_status(:found)
    expect(legacy.access_grants.sole.scopes.to_a).to match_array(Mcp::OauthClientRegistration::MCP_SCOPES)
    expect(legacy.reload.scopes.to_s).to eq("account")
  end

  it "refuses a scope registration never grants, on the consent page and on submit" do
    expect do
      get "/claude/v1/oauth2/authorize", params: authorize_params(scope: "view_public edit_emails")
      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("The requested scope is invalid, unknown, or malformed.")

      fields = consent_form_fields(authorize_params(scope: "view_public view_library"))
      post "/oauth/authorize", params: fields.merge("scope" => "view_public edit_emails")
      expect(response.location).to include("error=invalid_scope")
    end.not_to change(Doorkeeper::AccessGrant, :count)
  end

  it "keeps the error from a later check when the newer scope is accepted" do
    expect do
      get "/claude/v1/oauth2/authorize", params: authorize_params(scope: "view_public view_library").merge(code_challenge_method: "unsupported")
    end.not_to change(Doorkeeper::AccessGrant, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.body).to include("The code challenge method must be plain or S256.")
  end

  it "keeps the registered scopes as the limit for an application that was not dynamically registered" do
    ordinary = create(:oauth_application, scopes: registered_scopes, redirect_uri:)

    get "/oauth/authorize", params: authorize_params(scope: "view_public view_library", client_id: ordinary.uid)

    expect(response).to have_http_status(:bad_request)
    expect(response.body).to include("The requested scope is invalid, unknown, or malformed.")
  end

  it "sends a denied consent back with access_denied, since the Deny form carries the resource" do
    fields = consent_form_fields(authorize_params(scope: "view_public view_library"), method: "delete")
    expect(fields["resource"]).to eq(resource)

    delete "/oauth/authorize", params: fields

    expect(response.location).to include("error=access_denied")
    expect(application.access_grants).to be_empty
  end
end
