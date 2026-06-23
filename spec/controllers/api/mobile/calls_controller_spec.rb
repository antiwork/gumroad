# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::CallsController do
  before do
    @seller = create(:user, :eligible_for_service_products)
    @app = create(:oauth_application, owner: @seller)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
    }
    @product = create(:call_product, :available_for_a_year, user: @seller)
    @purchase = create(:call_purchase, link: @product, seller: @seller)
    @call = @purchase.call
  end

  describe "PUT update" do
    it "updates the call URL" do
      put :update, params: @params.merge(id: @call.external_id, call_url: "https://zoom.us/j/updated")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@call.reload.call_url).to eq("https://zoom.us/j/updated")
    end

    it "returns 404 for another seller's call" do
      other_seller = create(:user, :eligible_for_service_products)
      other_purchase = create(:call_purchase, link: create(:call_product, :available_for_a_year, user: other_seller), seller: other_seller)
      other_call = other_purchase.call

      put :update, params: @params.merge(id: other_call.external_id, call_url: "https://zoom.us/j/hacked")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq(false)
      expect(other_call.reload.call_url).not_to eq("https://zoom.us/j/hacked")
    end
  end
end
