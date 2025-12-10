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
      expect(purchases.first["id"]).to eq(purchase.id)

      expect(response.parsed_body["pagination"]).to be_present
    end

    it "returns only purchases for the specified product" do
      other_product = create(:product)
      other_purchase = create(:purchase, link: other_product)

      get :index, params: { product_external_id: product.external_id }, format: :json

      expect(response).to have_http_status(:ok)

      purchases = response.parsed_body["purchases"]
      purchase_ids = purchases.map { |p| p["id"] }

      expect(purchase_ids).to include(purchase.id)
      expect(purchase_ids).not_to include(other_purchase.id)
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
end
