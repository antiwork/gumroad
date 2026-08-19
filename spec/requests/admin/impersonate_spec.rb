# frozen_string_literal: true

require "spec_helper"

# The admin web UI is gone; impersonation is entered via a direct GET
# (Helper / CLI admin_links) and cleared via DELETE unimpersonate or logout.
describe "Impersonate", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user, name: "Gumlord") }
  let(:seller) do
    user = create(:named_seller)
    # Admin lookup by Stripe account ID is a plain database find_by on this
    # string (Admin::BaseController#find_user), so the account only has to exist
    # in our own records. See #6502.
    create(:merchant_account, user:, charge_processor_merchant_id: "acct_1TestImpersonate")
    user
  end

  # `protect_from_forgery` null-sessions unverified non-GET requests, which
  # would sign the admin out before unimpersonate runs.
  around do |example|
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = true
  end

  before do
    host! DOMAIN
    sign_in admin
  end

  it "impersonates a seller by email, username, and Stripe account ID" do
    [seller.email, seller.username, seller.merchant_accounts.sole.charge_processor_merchant_id].each do |identifier|
      get admin_impersonate_path(user_identifier: identifier)

      expect(response).to redirect_to(products_path)
      expect($redis.get(RedisKey.impersonated_user(admin.id)).to_i).to eq(seller.id)

      delete admin_unimpersonate_path, as: :json

      expect(response.parsed_body["redirect_to"]).to eq(root_url)
      expect($redis.get(RedisKey.impersonated_user(admin.id))).to be_nil
    end
  end

  it "impersonates a suspended seller" do
    seller.update!(user_risk_state: "suspended_for_fraud")

    get admin_impersonate_path(user_identifier: seller.email)

    expect(response).to redirect_to(products_path)
    expect($redis.get(RedisKey.impersonated_user(admin.id)).to_i).to eq(seller.id)
  end

  it "redirects with an alert when the user is not found" do
    get admin_impersonate_path(user_identifier: "nobody@example.com")

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq("User not found")
  end

  it "is not available to non-team members" do
    sign_in create(:user)

    get admin_impersonate_path(user_identifier: seller.email)

    expect(response).to redirect_to(root_path)
  end

  it "redirects logged-out visitors to login" do
    sign_out admin

    get admin_impersonate_path(user_identifier: seller.email)

    expect(response).to redirect_to(login_path(next: admin_impersonate_path))
  end
end
