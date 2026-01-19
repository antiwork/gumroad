# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe Products::AvailableDiscountCodesController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    context "authenticated as user with access to seller account" do
      it_behaves_like "authorize called for action", :get, :index do
        let(:record) { product }
        let(:policy_method) { :edit? }
        let(:request_params) { { product_id: product.unique_permalink } }
        let(:request_format) { :json }
      end

      context "with product offer codes" do
        let!(:product_offer_code) { create(:offer_code, user: seller, name: "Product Specific", code: "PRODUCTCODE", products: [product]) }
        let!(:universal_offer_code) { create(:universal_offer_code, user: seller, name: "Universal Code", code: "UNIVERSALCODE", currency_type: product.price_currency_type) }

        it "returns product and universal offer codes" do
          get :index, format: :json, params: { product_id: product.unique_permalink }

          expect(response).to be_successful
          parsed_body = response.parsed_body
          expect(parsed_body).to be_an(Array)
          expect(parsed_body.length).to eq(2)

          codes = parsed_body.map { |code| code["code"] }
          expect(codes).to include(product_offer_code.code, universal_offer_code.code)
        end

        it "returns offer codes with correct structure" do
          get :index, format: :json, params: { product_id: product.unique_permalink }

          expect(response).to be_successful
          first_code = response.parsed_body.first
          expect(first_code).to have_key("id")
          expect(first_code).to have_key("code")
          expect(first_code).to have_key("name")
          expect(first_code).to have_key("discount")
        end
      end

      context "with search query" do
        let!(:matching_offer_code) { create(:offer_code, user: seller, name: "Summer Sale", code: "SUMMERCODE", products: [product]) }
        let!(:non_matching_offer_code) { create(:offer_code, user: seller, name: "Winter Discount", code: "WINTERCODE", products: [product]) }

        it "returns only matching offer codes" do
          get :index, format: :json, params: { product_id: product.unique_permalink, query: "Summer" }

          expect(response).to be_successful
          parsed_body = response.parsed_body
          expect(parsed_body.length).to eq(1)
          expect(parsed_body.first["name"]).to eq("Summer Sale")
        end
      end

      context "with empty search results" do
        let!(:offer_code) { create(:offer_code, user: seller, name: "Summer Sale", code: "EMPTYCODE", products: [product]) }

        it "returns empty array when query matches nothing" do
          get :index, format: :json, params: { product_id: product.unique_permalink, query: "NonExistentCode" }

          expect(response).to be_successful
          expect(response.parsed_body).to eq([])
        end
      end

      context "with no offer codes" do
        it "returns empty array" do
          get :index, format: :json, params: { product_id: product.unique_permalink }

          expect(response).to be_successful
          expect(response.parsed_body).to eq([])
        end
      end

      context "with MAX_OFFER_CODES_LIMIT" do
        before do
          (Products::AvailableDiscountCodesController::MAX_OFFER_CODES_LIMIT + 5).times do |i|
            create(:offer_code, user: seller, name: "Code #{i}", code: "LIMITCODE#{i}", products: [product])
          end
        end

        it "enforces the limit" do
          get :index, format: :json, params: { product_id: product.unique_permalink }

          expect(response).to be_successful
          expect(response.parsed_body.length).to eq(Products::AvailableDiscountCodesController::MAX_OFFER_CODES_LIMIT)
        end
      end

      context "with universal offer codes" do
        let!(:universal_offer_code) { create(:universal_offer_code, user: seller, name: "Universal Code", code: "UNIVERSALCODE2", currency_type: product.price_currency_type) }

        it "includes universal offer codes with matching currency" do
          get :index, format: :json, params: { product_id: product.unique_permalink }

          expect(response).to be_successful
          codes = response.parsed_body.map { |code| code["code"] }
          expect(codes).to include(universal_offer_code.code)
        end
      end
    end

    context "with product that doesn't belong to seller" do
      let(:other_seller) { create(:user) }
      let(:other_product) { create(:product, user: other_seller) }

      it "returns unauthorized" do
        get :index, format: :json, params: { product_id: other_product.unique_permalink }

        expect(response).to have_http_status :unauthorized
        expect(response.parsed_body).to have_key("success")
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body).to have_key("error")
        expect(response.parsed_body["error"]).to be_present
      end
    end

    context "unauthenticated" do
      before do
        sign_out(seller)
      end

      it "returns 404" do
        get :index, format: :json, params: { product_id: product.unique_permalink }

        expect(response).to have_http_status :not_found
        expect(response.parsed_body).to eq(
          "success" => false,
          "error" => "Not found"
        )
      end
    end

    context "for an invalid product ID" do
      it "returns 404" do
        expect do
          get :index, format: :json, params: { product_id: "fake-id-123" }
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
