# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::SubscriptionsController do
  describe "POST cancel" do
    before do
      @seller = create(:user)
      @app = create(:oauth_application, owner: @seller)
      @params = {
        mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
        access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
      }
      @product = create(:membership_product, user: @seller)
      @subscription = create(:subscription, link: @product, seller: @seller)
      create(:purchase, link: @product, seller: @seller, subscription: @subscription, is_original_subscription_purchase: true)
    end

    it "cancels the subscription by seller" do
      expect_any_instance_of(Subscription).to receive(:cancel!).with(by_seller: true)

      post :cancel, params: @params.merge(id: @subscription.external_id)

      expect(response.parsed_body["success"]).to eq(true)
    end

    it "returns 404 for another seller's subscription" do
      other = create(:subscription)

      post :cancel, params: @params.merge(id: other.external_id)

      expect(response).to have_http_status(:not_found)
    end
  end
end
