# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::LicensesController do
  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
    }
    @product = create(:product, user: @seller, is_licensed: true)
    @purchase = create(:purchase, link: @product, seller: @seller)
    @license = create(:license, link: @product, purchase: @purchase)
  end

  describe "PUT update" do
    it "disables and enables the license" do
      put :update, params: @params.merge(id: @license.external_id, enabled: "false")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@license.reload.disabled?).to eq(true)

      put :update, params: @params.merge(id: @license.external_id, enabled: "true")

      expect(@license.reload.disabled?).to eq(false)
    end

    it "returns 404 for another seller's license" do
      other_seller = create(:user)
      other_purchase = create(:purchase, link: create(:product, user: other_seller, is_licensed: true), seller: other_seller)
      other_license = create(:license, link: other_purchase.link, purchase: other_purchase)

      put :update, params: @params.merge(id: other_license.external_id, enabled: "false")

      expect(response).to have_http_status(:not_found)
      expect(other_license.reload.disabled?).to eq(false)
    end
  end
end
