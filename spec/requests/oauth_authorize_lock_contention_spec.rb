# frozen_string_literal: true

require "spec_helper"

describe "OAuth authorize while the application row is held", type: :request do
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false

  before do
    host! DOMAIN
    stub_vite_layout_helpers
    allow_any_instance_of(OauthApplication).to receive(:sleep)
    stub_const("OauthApplication::LOCK_WAIT_SECONDS", 1)
    @user = create(:named_user)
    @suspended_user = create(:named_user)
    @owner = create(:named_user)
    @application = create(:oauth_application, owner: @owner, redirect_uri: "https://example.com/callback", confidential: false)
    # The mobile app skips consent, so GET /oauth/authorize issues its grant under the application row.
    stub_const("OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID", @application.uid)
    # Devise builds its mappings when routes are drawn; sign in only after drawing them.
    Rails.application.reload_routes!
    sign_in @user
  end

  after do
    if @application
      Doorkeeper::AccessGrant.where(application_id: @application.id).delete_all
      Doorkeeper::AccessToken.where(application_id: @application.id).delete_all
      @application.delete
    end
    users = [@user, @suspended_user, @owner].compact
    users.each(&:destroy!)
    delete_leftovers(user_ids: users.map(&:id))
  end

  let(:authorize_params) do
    { response_type: "code", client_id: @application.uid, redirect_uri: @application.redirect_uri, scope: "edit_products" }
  end

  it "signs the mobile app in while a suspension still holds that user's token revocation open" do
    create("doorkeeper/access_token", application: @application, resource_owner_id: @suspended_user.id, scopes: "edit_products")

    while_held_elsewhere(-> { OauthApplication.find(@application.id).revoke_access_tokens_for(@suspended_user) }) do
      expect do
        Timeout.timeout(10) { get "/oauth/authorize", params: authorize_params }
      end.to change { @application.access_grants.count }.by(1)

      expect(response).to redirect_to(%r{\Ahttps://example\.com/callback\?code=})
    end
  end

  it "asks for a retry instead of failing when a credential sweep holds the application" do
    sweep = lambda do
      application = OauthApplication.find(@application.id)
      application.with_application_lock { application.update!(scopes: "view_public") }
    end
    expect(ErrorNotifier).to receive(:notify).with(an_instance_of(OauthApplication::LockUnavailable), client_id: @application.uid)

    while_held_elsewhere(sweep) do
      expect do
        get "/oauth/authorize", params: authorize_params
      end.not_to change { @application.access_grants.count }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq(Oauth::AuthorizationsController::LOCK_RETRY_AFTER_SECONDS.to_s)
      expect(response.body).to include(Oauth::AuthorizationsController::LOCK_BUSY_MESSAGE)
    end
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
