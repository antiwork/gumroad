# frozen_string_literal: true

require "spec_helper"

describe "OAuth consent for an MCP client registered before view_library", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_user) }
  let(:resource) { Mcp::DynamicClientOauth.resource_identifier("/claude/v1/mcp") }
  # Through the real registration path: a dynamic client has no owner, which is what the consent
  # save has to cope with.
  let(:application) do
    payload = Mcp::OauthClientRegistration.create!(client_name: "Claude", redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
                                                   token_endpoint_auth_method: "none", scope: "view_public view_profile view_sales")
    OauthApplication.find_by!(uid: payload.fetch(:client_id))
  end
  let(:params) do
    { response_type: "code", client_id: application.uid, redirect_uri: application.redirect_uri, scope: "view_public view_library",
      code_challenge: "a" * 43, code_challenge_method: "S256", resource: }
  end

  before do
    host! DOMAIN
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
    Rails.application.reload_routes!
    application.update_columns(scopes: "view_public view_profile view_sales")
    sign_in user
  end

  it "shows the consent screen without changing the client until the person agrees" do
    get "/oauth/authorize", params: params

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("See the products you bought.")
    expect(application.reload.scopes.to_s).to eq("view_public view_profile view_sales")
  end

  it "adds view_library to the client when the person consents" do
    allow_any_instance_of(ActionController::Base).to receive(:verify_authenticity_token)
    post "/oauth/authorize", params: params.merge(consented_account: "")

    expect(application.reload.scopes.to_s.split).to include("view_library")
    expect(Doorkeeper::AccessGrant.where(application_id: application.id).last.scopes.to_s).to eq("view_public view_library")
  end

  it "leaves the client alone when the request is refused" do
    allow_any_instance_of(ActionController::Base).to receive(:verify_authenticity_token)

    expect do
      post "/oauth/authorize", params: params.merge(resource: "https://evil.example/mcp", consented_account: "")
    end.not_to change { application.reload.scopes.to_s }

    expect(response).to have_http_status(:found)
    expect(Rack::Utils.parse_query(URI.parse(response.location).query)).to include("error" => "invalid_target")
  end

  it "does not widen a client for a scope outside the late list" do
    get "/oauth/authorize", params: params.merge(scope: "view_public edit_products")

    expect(response.body).to include("Remove the connector in Settings")
    expect(application.reload.scopes.to_s).not_to include("edit_products")
  end

  it "refuses an unknown scope with an explanation, not the protocol error" do
    get "/oauth/authorize", params: params.merge(scope: "view_public bogus")

    expect(response.body).not_to include("invalid, unknown, or malformed")
    expect(response.body).to include("Remove the connector in Settings")
  end
end
