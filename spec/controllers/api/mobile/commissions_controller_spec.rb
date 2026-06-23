# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::CommissionsController, :vcr do
  before do
    @seller = create(:user, :eligible_for_service_products)
    @app = create(:oauth_application, owner: @seller)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
    }
    @commission = create(:commission, deposit_purchase: create(:purchase, seller: @seller, link: create(:commission_product, user: @seller), price_cents: 100, displayed_price_cents: 100, credit_card: create(:credit_card)))
  end

  describe "POST complete" do
    it "creates a completion purchase" do
      expect_any_instance_of(Commission).to receive(:create_completion_purchase!).and_call_original

      post :complete, params: @params.merge(id: @commission.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      @commission.reload
      expect(@commission.completion_purchase).to be_present
      expect(@commission.status).to eq(Commission::STATUS_COMPLETED)
    end

    it "returns an error when completion fails" do
      allow_any_instance_of(Commission).to receive(:create_completion_purchase!).and_raise(ActiveRecord::RecordInvalid.new)

      post :complete, params: @params.merge(id: @commission.external_id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("success" => false, "message" => "Failed to complete commission")
    end

    it "returns 404 for another seller's commission" do
      other_seller = create(:user, :eligible_for_service_products)
      other_commission = create(:commission, deposit_purchase: create(:purchase, seller: other_seller, link: create(:commission_product, user: other_seller), price_cents: 100, displayed_price_cents: 100, credit_card: create(:credit_card)))

      post :complete, params: @params.merge(id: other_commission.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to eq(false)
      expect(other_commission.reload.completion_purchase).to be_nil
    end
  end
end
