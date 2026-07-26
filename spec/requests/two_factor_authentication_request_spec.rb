# frozen_string_literal: true

require "spec_helper"

describe "Two-Factor Authentication endpoint", type: :request do
  let(:user) { create(:user) }

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    allow_any_instance_of(TwoFactorAuthenticationController).to receive(:user_for_two_factor_authentication).and_return(user)
  end

  it "is successful with correct params" do
    post "/two-factor?user_id=#{user.encrypted_external_id}", params: { token: user.otp_code }

    expect(response).to redirect_to(controller.send(:login_path_for, user))
  end

  # This is important to make sure rate limiting works as expected. We send the user_id in the query string
  # (see app/javascript/data/login.ts) because we rate limit on user_id, and Rack::Attack does not parse JSON request bodies.
  # If Rails ever starts prioritising body params over query string params, users would be able to brute force OTP codes by
  # sending a random user_id (for rate limiting) in the query and the correct one (for the controller to parse) in the body.
  it "prioritises user_id in the query string over POST body" do
    post "/two-factor?user_id=invalid-id", params: { token: user.otp_code, user_id: user.encrypted_external_id }

    expect(response).to have_http_status(:not_found)
  end

  context "when there is no pending two-factor login in the session" do
    before do
      allow_any_instance_of(TwoFactorAuthenticationController).to receive(:user_for_two_factor_authentication).and_return(nil)
    end

    it "sends the visitor back to the login page instead of 404ing" do
      get "/two-factor"

      expect(response).to redirect_to(login_url(next: "/two-factor"))
    end

    it "keeps the page the visitor was headed to in the next param" do
      get "/two-factor?next=/dashboard"

      expect(response).to redirect_to(login_url(next: "/two-factor?next=/dashboard"))
    end

    # The POST actions are the ones whose behavior actually changed here: they used to raise a hard
    # 404. They are driven by the Inertia client, which follows a 303 and renders the login page.
    it "redirects a token submission to login rather than 404ing" do
      post "/two-factor?user_id=#{user.encrypted_external_id}",
           params: { token: user.otp_code },
           headers: { "X-Inertia" => "true", "X-Inertia-Version" => InertiaRails.configuration.version.to_s }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(login_url)
    end

    it "redirects a resend request to login rather than 404ing" do
      post "/two-factor/resend_authentication_token?user_id=#{user.encrypted_external_id}"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(login_url)
    end
  end
end
