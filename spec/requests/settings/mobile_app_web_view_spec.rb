# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Settings mobile app WebView authentication", type: :request, inertia: true do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_seller) }
  let(:oauth_app) { create(:oauth_application, owner: user) }
  let(:access_token) { create("doorkeeper/access_token", application: oauth_app, resource_owner_id: user.id, scopes: "mobile_api") }
  let(:mobile_token) { Api::Mobile::BaseController::MOBILE_TOKEN }

  before do
    create(:user_compliance_info, country: "United States", user:)
    host! DOMAIN
  end

  def inertia_props
    JSON.parse(response.body)["props"]
  end

  context "with ?display=mobile_app, a valid access_token and the correct mobile_token" do
    it "signs the token's user into a web session and flags the Inertia prop" do
      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }, headers: { "X-Inertia" => "true" }

      expect(response).to be_successful
      expect(inertia_props["is_mobile_app_web_view"]).to eq(true)
    end

    it "establishes a web session so a follow-up request without the token stays authenticated" do
      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }, headers: { "X-Inertia" => "true" }
      expect(response).to be_successful

      get settings_payments_path, headers: { "X-Inertia" => "true" }
      expect(response).to be_successful
    end
  end

  context "without an access_token" do
    it "does not sign the user in and redirects to login" do
      get settings_payments_path

      expect(response).to redirect_to(login_path(next: settings_payments_path))
    end

    it "reports is_mobile_app_web_view as false when there is no display param and no stored flag" do
      sign_in user

      get settings_payments_path, headers: { "X-Inertia" => "true" }

      expect(response).to be_successful
      expect(inertia_props["is_mobile_app_web_view"]).to eq(false)
    end
  end

  context "with a wrong mobile_token" do
    it "does not sign the user in and behaves like an unauthenticated request" do
      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: "wrong_token" }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include(login_path)

      # The session was not established: a follow-up request without params still bounces to login.
      get settings_payments_path
      expect(response.location).to include(login_path)
    end
  end

  context "with a blank mobile_token" do
    it "does not sign the user in and behaves like an unauthenticated request" do
      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: "" }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include(login_path)

      get settings_payments_path
      expect(response.location).to include(login_path)
    end
  end

  context "flag persistence" do
    it "persists is_mobile_app_web_view across a later request that drops the display param" do
      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }, headers: { "X-Inertia" => "true" }
      expect(response).to be_successful
      expect(inertia_props["is_mobile_app_web_view"]).to eq(true)

      # Simulate an Inertia re-render after a save: same session, but the WebView's
      # ?display=mobile_app query param is no longer present.
      get settings_payments_path, headers: { "X-Inertia" => "true" }
      expect(response).to be_successful
      expect(inertia_props["is_mobile_app_web_view"]).to eq(true)
    end
  end

  context "with a revoked access_token" do
    it "does not sign the user in via the WebView path" do
      access_token.update!(revoked_at: 1.hour.ago)

      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }

      expect(response).not_to be_successful
    end
  end

  context "with an access_token that lacks the mobile_api scope" do
    let(:access_token) { create("doorkeeper/access_token", application: oauth_app, resource_owner_id: user.id, scopes: "creator_api") }

    it "is forbidden by doorkeeper and does not sign the user in" do
      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }

      expect(response).to have_http_status(:forbidden)
    end
  end

  context "with an existing web session and a stale token still in the URL" do
    it "uses the session instead of failing on the revoked token" do
      sign_in user
      access_token.update!(revoked_at: 1.hour.ago)

      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }, headers: { "X-Inertia" => "true" }

      expect(response).to be_successful
    end
  end

  context "flag storage" do
    # The flag lives in the session (not a standalone persistent cookie) so it is
    # cleared by logout's session reset and can't leak into a later web-only session.
    it "keeps the flag in the session and never sets a standalone is_mobile_app_web_view cookie" do
      get settings_payments_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }, headers: { "X-Inertia" => "true" }

      expect(inertia_props["is_mobile_app_web_view"]).to eq(true)
      expect(session[:mobile_app_web_view]).to eq(true)
      expect(cookies[:is_mobile_app_web_view]).to be_blank
    end
  end
end
