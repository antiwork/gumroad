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
end
