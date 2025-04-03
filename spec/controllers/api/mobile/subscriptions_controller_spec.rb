# frozen_string_literal: true

require "spec_helper"
require "net/http"

describe Api::Mobile::SubscriptionsController, :vcr do
  before do
    @product = create(:subscription_product, user: create(:user))
    @user = create(:user, credit_card: create(:credit_card))
    @subscription = create(:subscription, link: @product, user: @user, created_at: 3.days.ago)
    @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
    @very_old_post = create(:installment, link: @product, created_at: 5.months.ago, published_at: 5.months.ago)
    @old_post = create(:installment, link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
    @new_post = create(:installment, link: @product, published_at: Time.current)
    @unpublished_post = create(:installment, link: @product, published_at: nil)
  end

  it "returns an error response for a dead subscription" do
    @subscription.cancel_effective_immediately!
    get :subscription_attributes, params: { id: @subscription.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
    assert_response :not_found
    expect(response.parsed_body).to eq({
      success: false,
      message: "Could not find subscription"
    }.as_json)
  end

  it "returns the correct information if the subscription is still alive" do
    get :subscription_attributes, params: { id: @subscription.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
    assert_response 200
    expect(response.parsed_body).to eq({ success: true, subscription: @subscription.subscription_mobile_json_data }.as_json)
  end
end
