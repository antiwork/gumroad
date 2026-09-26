# frozen_string_literal: true

require "spec_helper"

describe "OAuth authorize consent screen", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_user) }

  before do
    host! DOMAIN
    stub_vite_layout_helpers
    # Devise builds its mappings when routes are drawn; sign in only after drawing them.
    Rails.application.reload_routes!
    sign_in user
  end

  it "names the destination host the code will be sent to, and how to revoke access" do
    application = create(:oauth_application, owner: create(:named_user), redirect_uri: "https://claude.ai/api/mcp/auth_callback", confidential: false, scopes: "view_public")

    get "/oauth/authorize", params: {
      response_type: "code",
      client_id: application.uid,
      redirect_uri: application.redirect_uri,
      scope: "view_public"
    }

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.text).to include("Your authorization code will be sent to claude.ai")
    expect(document.at_css('a[href="/settings/authorized_applications"]')).to be_present
  end

  it "omits the destination when the client registered an out-of-band redirect" do
    application = create(:oauth_application, owner: create(:named_user), redirect_uri: "urn:ietf:wg:oauth:2.0:oob", confidential: false, scopes: "view_public")

    get "/oauth/authorize", params: {
      response_type: "code",
      client_id: application.uid,
      redirect_uri: application.redirect_uri,
      scope: "view_public"
    }

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).text).not_to include("Your authorization code will be sent to")
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
