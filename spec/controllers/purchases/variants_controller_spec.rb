# frozen_string_literal: false

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe Purchases::VariantsController do
  it_behaves_like "inherits from Sellers::BaseController"

  describe "PUT update" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:category) { create(:variant_category, link: product, title: "Color") }
    let(:blue_variant) { create(:variant, variant_category: category, name: "Blue") }
    let(:green_variant) { create(:variant, variant_category: category, name: "Green") }
    let(:purchase) { create(:purchase, link: product, variant_attributes: [blue_variant]) }

    context "authenticated as a different user" do
      it "returns a 404" do
        user = create(:user)
        product = create(:product)
        category = create(:variant_category, link: product, title: "Color")
        blue_variant = create(:variant, variant_category: category, name: "Blue")

        purchase = create(:purchase, link: product)

        sign_in user

        put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: blue_variant.external_id, quantity: purchase.quantity }

        expect(response).to have_http_status :not_found
        expect(response.parsed_body).to eq(
          "success" => false,
          "error" => "Not found"
        )
      end
    end

    context "unauthenticated" do
      it "returns a 404" do
        product = create(:product)
        category = create(:variant_category, link: product, title: "Color")
        blue_variant = create(:variant, variant_category: category, name: "Blue")

        purchase = create(:purchase, link: product)

        put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: blue_variant.external_id, quantity: purchase.quantity }

        expect(response).to have_http_status :not_found
        expect(response.parsed_body).to eq(
          "success" => false,
          "error" => "Not found"
        )
      end
    end

    context "with user signed in as admin for seller" do
      include_context "with user signed in as admin for seller"

      it_behaves_like "authorize called for action", :put, :update do
        let(:record) { purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:request_params) { { purchase_id: purchase.external_id, variant_id: green_variant.external_id } }
      end

      it "updates the variant for the given category" do
        put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: green_variant.external_id, quantity: purchase.quantity + 1 }

        expect(response).to be_successful
        purchase.reload
        expect(purchase.variant_attributes).to eq [green_variant]
        expect(purchase.quantity).to eq 2
      end

      context "for a product with SKUs" do
        it "updates the SKU" do
          product = create(:physical_product, user: seller)
          create(:variant_category, link: product, title: "Color")
          create(:variant_category, link: product, title: "Size")
          large_blue_sku = create(:sku, link: product, name: "Blue - large")
          small_green_sku = create(:sku, link: product, name: "Green - small")

          purchase = create(:physical_purchase, link: product, variant_attributes: [large_blue_sku])

          put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: small_green_sku.external_id, quantity: purchase.quantity }

          expect(response).to be_successful
          expect(purchase.reload.variant_attributes).to eq [small_green_sku]
        end
      end

      context "for a product without an associated variant" do
        let(:purchase) { create(:purchase, link: product) }

        it "adds the variant" do
          put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: green_variant.external_id, quantity: purchase.quantity }

          expect(response).to be_successful
          expect(purchase.reload.variant_attributes).to eq [green_variant]
        end
      end

      context "when the new variant has insufficient inventory" do
        let(:blue_variant) { create(:variant, variant_category: category, name: "Blue", max_purchase_count: 2) }
        let(:purchase) { create(:purchase, link: product, variant_attributes: [green_variant]) }

        it "returns an unsuccessful response" do
          put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: blue_variant.external_id, quantity: 3 }

          expect(response).to_not be_successful
          purchase.reload
          expect(purchase.variant_attributes).to eq [green_variant]
          expect(purchase.quantity).to eq 1
        end
      end

      context "with an invalid variant ID" do
        it "returns an unsuccessful response" do
          purchase = create(:purchase, link: product)

          put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: "fake-id-123", quantity: purchase.quantity }

          expect(response).to_not be_successful
        end
      end

      context "when the existing variant has insuffient inventory" do
        it "returns an unsuccessful response" do
          purchase = create(:purchase, link: product)
          green_variant.update!(max_purchase_count: 1)

          put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: green_variant.external_id, quantity: purchase.quantity + 1 }

          expect(response).to_not be_successful
          expect(purchase.reload.quantity).to eq 1
        end
      end
    end
  end

  context "authenticated as a different user" do
    it "returns a 404" do
      user = create(:user)
      product = create(:product)
      category = create(:variant_category, link: product, title: "Color")
      blue_variant = create(:variant, variant_category: category, name: "Blue")

      purchase = create(:purchase, link: product)

      sign_in user

      put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: blue_variant.external_id, quantity: purchase.quantity }

      expect(response).to_not be_successful
      expect(response).to have_http_status :not_found
    end
  end

  context "unauthenticated" do
    it "returns a 404" do
      product = create(:product)
      category = create(:variant_category, link: product, title: "Color")
      blue_variant = create(:variant, variant_category: category, name: "Blue")

      purchase = create(:purchase, link: product)

      put :update, format: :json, params: { purchase_id: purchase.external_id, variant_id: blue_variant.external_id, quantity: purchase.quantity }

      expect(response).to_not be_successful
      expect(response).to have_http_status :not_found
    end
  end
end
