# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Affiliates::Products::PurchasesController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    let(:product) { create(:product) }
    let(:affiliate_user) { create(:user) }
    let(:affiliate) { create(:direct_affiliate, affiliate_user: affiliate_user, seller: product.user) }
    let!(:affiliate_purchase) { create(:purchase, link: product, affiliate: affiliate) }

    it "returns purchases and pagination for the affiliate" do
      get :index, params: { product_external_id: product.external_id, affiliate_external_id: affiliate_user.external_id }, format: :json

      expect(response).to have_http_status(:ok)

      purchases = response.parsed_body["purchases"]
      expect(purchases).to be_present
      expect(purchases.length).to eq(1)
      expect(purchases.first["external_id"]).to eq(affiliate_purchase.external_id)

      expect(response.parsed_body["pagination"]).to be_present
    end

    it "returns only purchases for the affiliate user" do
      non_affiliate_purchase = create(:purchase, link: product, affiliate: nil)
      other_affiliate = create(:direct_affiliate, affiliate_user: create(:user), seller: product.user)
      other_affiliate_purchase = create(:purchase, link: product, affiliate: other_affiliate)

      get :index, params: { product_external_id: product.external_id, affiliate_external_id: affiliate_user.external_id }, format: :json

      expect(response).to have_http_status(:ok)

      purchases = response.parsed_body["purchases"]
      purchase_external_ids = purchases.map { |p| p["external_id"] }

      expect(purchase_external_ids).to include(affiliate_purchase.external_id)
      expect(purchase_external_ids).not_to include(non_affiliate_purchase.external_id)
      expect(purchase_external_ids).not_to include(other_affiliate_purchase.external_id)
    end

    it "does not return affiliate purchases from other products" do
      other_product = create(:product)
      other_affiliate = create(:direct_affiliate, affiliate_user: affiliate_user, seller: other_product.user)
      other_product_purchase = create(:purchase, link: other_product, affiliate: other_affiliate)

      get :index, params: { product_external_id: product.external_id, affiliate_external_id: affiliate_user.external_id }, format: :json

      expect(response).to have_http_status(:ok)

      purchases = response.parsed_body["purchases"]
      purchase_external_ids = purchases.map { |p| p["external_id"] }

      expect(purchase_external_ids).to include(affiliate_purchase.external_id)
      expect(purchase_external_ids).not_to include(other_product_purchase.external_id)
    end

    context "with pagination parameters" do
      before do
        create_list(:purchase, 7, link: product, affiliate: affiliate)
      end

      it "accepts per_page and page parameters" do
        get :index, params: { product_external_id: product.external_id, affiliate_external_id: affiliate_user.external_id, per_page: 5, page: 1 }, format: :json

        expect(response).to have_http_status(:ok)

        purchases = response.parsed_body["purchases"]
        expect(purchases).to be_present
        expect(purchases.length).to eq(5)

        pagination = response.parsed_body["pagination"]
        expect(pagination).to be_present
      end

      it "returns the correct page of results" do
        get :index, params: { product_external_id: product.external_id, affiliate_external_id: affiliate_user.external_id, per_page: 5, page: 2 }, format: :json

        expect(response).to have_http_status(:ok)

        purchases = response.parsed_body["purchases"]
        expect(purchases).to be_present
        expect(purchases.length).to eq(3) # 8 total - 5 on page 1 = 3 on page 2
      end

      it "respects per_page limit" do
        get :index, params: { product_external_id: product.external_id, affiliate_external_id: affiliate_user.external_id, per_page: 3, page: 1 }, format: :json

        expect(response).to have_http_status(:ok)

        purchases = response.parsed_body["purchases"]
        expect(purchases.length).to eq(3)
      end
    end
  end
end
