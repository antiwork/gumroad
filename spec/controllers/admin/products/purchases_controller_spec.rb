# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Products::PurchasesController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    let(:product) { create(:product) }
    let!(:purchase) { create(:purchase, link: product) }

    it "returns purchases and pagination" do
      get :index, params: { product_external_id: product.external_id }, format: :json

      expect(response).to have_http_status(:ok)

      purchases = response.parsed_body["purchases"]
      expect(purchases).to be_present
      expect(purchases.length).to eq(1)
      expect(purchases.first["external_id"]).to eq(purchase.external_id)

      expect(response.parsed_body["pagination"]).to be_present
    end

    it "returns only purchases for the specified product" do
      other_product = create(:product)
      other_purchase = create(:purchase, link: other_product)

      get :index, params: { product_external_id: product.external_id }, format: :json

      expect(response).to have_http_status(:ok)

      purchases = response.parsed_body["purchases"]
      purchase_external_ids = purchases.map { |p| p["external_id"] }

      expect(purchase_external_ids).to include(purchase.external_id)
      expect(purchase_external_ids).not_to include(other_purchase.external_id)
    end

    context "with pagination parameters" do
      before do
        create_list(:purchase, 7, link: product)
      end

      it "accepts per_page and page parameters" do
        get :index, params: { product_external_id: product.external_id, per_page: 5, page: 1 }, format: :json

        expect(response).to have_http_status(:ok)

        purchases = response.parsed_body["purchases"]
        expect(purchases).to be_present
        expect(purchases.length).to eq(5)

        pagination = response.parsed_body["pagination"]
        expect(pagination).to be_present
      end

      it "returns the correct page of results" do
        get :index, params: { product_external_id: product.external_id, per_page: 5, page: 2 }, format: :json

        expect(response).to have_http_status(:ok)

        purchases = response.parsed_body["purchases"]
        expect(purchases).to be_present
        expect(purchases.length).to eq(3) # 8 total - 5 on page 1 = 3 on page 2
      end

      it "respects per_page limit" do
        get :index, params: { product_external_id: product.external_id, per_page: 3, page: 1 }, format: :json

        expect(response).to have_http_status(:ok)

        purchases = response.parsed_body["purchases"]
        expect(purchases.length).to eq(3)
      end
    end
  end

  describe "POST mass_refund_for_fraud" do
    let(:product) { create(:product) }
    let!(:successful_purchase) { create(:purchase, link: product) }
    let!(:failed_purchase) { create(:failed_purchase, link: product) }

    it "enqueues the job with correct parameters" do
      expect(MassRefundForFraudJob).to receive(:perform_async).with(
        product.id,
        [successful_purchase.external_id, failed_purchase.external_id],
        admin_user.id
      )

      post :mass_refund_for_fraud,
           params: { product_external_id: product.external_id, purchase_ids: [successful_purchase.external_id, failed_purchase.external_id] },
           format: :json

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body["success"]).to eq(true)
      expect(body["message"]).to include("Processing 2 fraud refunds")
    end

    it "requires purchase ids" do
      post :mass_refund_for_fraud, params: { product_external_id: product.external_id, purchase_ids: [] }, as: :json, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to eq(false)
    end

    it "rejects purchases that do not belong to the product" do
      other_purchase = create(:purchase)

      post :mass_refund_for_fraud,
           params: { product_external_id: product.external_id, purchase_ids: [other_purchase.external_id] },
           format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to eq(false)
    end
  end
end
