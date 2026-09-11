# frozen_string_literal: true

require "spec_helper"

# Real OmniAuth path (test_mode false). Does not prove vendor consent.
describe "TikTok OmniAuth flag-off", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user) }

  around do |example|
    previous = OmniAuth.config.test_mode
    previous_forgery = ActionController::Base.allow_forgery_protection
    OmniAuth.config.test_mode = false
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    OmniAuth.config.test_mode = previous
    ActionController::Base.allow_forgery_protection = previous_forgery
  end

  it "sends a signed-in seller to Social connections without creating an identity" do
    sign_in seller

    post "/users/auth/tiktok"

    expect(response).to redirect_to("/settings/social_connections")
    expect(seller.reload.tiktok_identity).to be_nil
    expect(seller.social_connect_verifications.find_by(platform: "tiktok")).to be_nil
  end

  it "uses the existing failure endpoint when onboarding return is present" do
    sign_in seller

    post "/users/auth/tiktok?social_connect_return=test-navigation-token"

    expect(response).to redirect_to("/settings/social_connections")
    expect(flash[:alert]).to eq("Couldn't connect TikTok. Please try again.")
    expect(seller.reload.tiktok_identity).to be_nil
    expect(seller.social_connect_verifications.find_by(platform: "tiktok")).to be_nil
  end

  it "does not create an identity on a flag-off callback" do
    sign_in seller

    get "/users/auth/tiktok/callback", params: { code: "authorization-code", state: "forged" }

    expect(response).to redirect_to("/settings/social_connections")
    expect(seller.reload.tiktok_identity).to be_nil
    expect(seller.social_connect_verifications.find_by(platform: "tiktok")).to be_nil
  end
end
