# frozen_string_literal: true

require "spec_helper"

describe "OAuth consent for an MCP client registered before view_library", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_user) }
  let(:resource) { Mcp::DynamicClientOauth.resource_identifier("/claude/v1/mcp") }
  let(:registered_scopes) { "view_public view_profile view_sales" }
  # Registered through the real path with the scopes clients received before view_library, so the
  # client is ownerless like every dynamic client in production.
  let(:application) do
    client = Mcp::OauthClientRegistration.create!(
      "client_name" => "Claude", "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"], "scope" => registered_scopes
    )
    OauthApplication.find_by!(uid: client[:client_id])
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
    sign_in user
  end

  def consent_form_fields(method: nil)
    get "/oauth/authorize", params: params
    expect(response).to have_http_status(:ok)
    form = Nokogiri::HTML(response.body).css("form").find { _1.at_css("input[name='_method']")&.[]("value") == method }
    form.css("input[type='hidden']").to_h { [_1["name"], _1["value"]] }
  end

  it "shows the consent screen without changing the client until the person agrees" do
    get "/oauth/authorize", params: params

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("See the products you bought.")
    expect(application.reload.scopes.to_s).to eq(registered_scopes)
  end

  it "adds view_library to the ownerless client when the person consents" do
    expect(application.owner).to be_nil

    post "/oauth/authorize", params: consent_form_fields

    expect(response).to have_http_status(:found)
    expect(application.reload.scopes.to_s).to eq("#{registered_scopes} view_library")
    expect(application.access_grants.sole.scopes.to_s).to eq("view_public view_library")
  end

  it "leaves the client unchanged when the consented request is rejected" do
    fields = consent_form_fields

    expect do
      post "/oauth/authorize", params: fields.merge("resource" => "https://evil.example/mcp")
    end.not_to change { application.access_grants.count }

    expect(response.location).to include("error=invalid_target")
    expect(application.reload.scopes.to_s).to eq(registered_scopes)
  end

  it "takes the client exclusively for a late scope it already has, since the lock decides from the request" do
    application.update_columns(scopes: "#{registered_scopes} view_library")
    fields = consent_form_fields
    expect_any_instance_of(OauthApplication).to receive(:with_application_lock).with(shared: false).and_call_original

    post "/oauth/authorize", params: fields

    expect(response).to have_http_status(:found)
    expect(application.reload.scopes.to_s).to eq("#{registered_scopes} view_library")
  end

  it "leaves the client unchanged when the person denies" do
    delete "/oauth/authorize", params: consent_form_fields(method: "delete")

    expect(response.location).to include("error=access_denied")
    expect(application.reload.scopes.to_s).to eq(registered_scopes)
    expect(application.access_grants).to be_empty
  end

  it "does not widen a client for a scope outside the late list" do
    fields = consent_form_fields

    post "/oauth/authorize", params: fields.merge("scope" => "view_public edit_products")

    expect(response.location).to include("error=invalid_scope")
    expect(application.reload.scopes.to_s).to eq(registered_scopes)
    expect(application.access_grants).to be_empty
  end

  it "explains a scope the client was not registered with instead of giving the protocol error" do
    get "/oauth/authorize", params: params.merge(scope: "view_public edit_products")

    expect(response).to have_http_status(:bad_request)
    expect(response.body).not_to include("invalid, unknown, or malformed")
    expect(response.body).to include("Claude can&#39;t connect to Gumroad because it asked for a permission it was not set up with. Remove Gumroad from Claude, then add it again.")
  end

  it "names the app plainly when it registered without a name" do
    client = Mcp::OauthClientRegistration.create!("redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"], "scope" => registered_scopes)

    get "/oauth/authorize", params: params.merge(client_id: client[:client_id], scope: "view_public edit_products")

    expect(response.body).to include("Your AI app can&#39;t connect to Gumroad because it asked for a permission it was not set up with. Remove Gumroad from your AI app, then add it again.")
  end

  it "keeps the protocol error for a scope that registering again would not grant" do
    get "/oauth/authorize", params: params.merge(scope: "view_public bogus")

    expect(response).to have_http_status(:bad_request)
    expect(response.body).to include("The requested scope is invalid, unknown, or malformed.")
  end

  it "keeps the protocol error when a late scope is fine but another check fails" do
    get "/oauth/authorize", params: params.merge(code_challenge_method: "unsupported")

    expect(response).to have_http_status(:bad_request)
    expect(response.body).to include("The code challenge method must be plain or S256.")
    expect(response.body).not_to include("asked for a permission")
  end

  it "keeps the protocol error for an application that was not dynamically registered" do
    ordinary = create(:oauth_application, scopes: registered_scopes)

    get "/oauth/authorize", params: params.merge(client_id: ordinary.uid, redirect_uri: ordinary.redirect_uri, scope: "view_public view_library")

    expect(response.body).to include("The requested scope is invalid, unknown, or malformed.")
    expect(ordinary.reload.scopes.to_s).to eq(registered_scopes)
  end
end
