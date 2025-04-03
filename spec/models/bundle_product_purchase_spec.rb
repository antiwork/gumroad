# frozen_string_literal: true

require "spec_helper"

describe BundleProductPurchase do
  describe "validations" do
    let(:bundle_product_purchase) { create(:bundle_product_purchase) }

    context "bundle product purchase is valid" do
      it "doesn't add an error" do
        expect(bundle_product_purchase).to be_valid
      end
    end

    context "bundle purchase and product purchase have different sellers" do
      before do
        product = create(:product)
        bundle_product_purchase.product_purchase.update!(seller: product.user, link: product)
      end

      it "adds an error" do
        expect(bundle_product_purchase).to_not be_valid
        expect(bundle_product_purchase.errors.full_messages.first).to eq("Seller must be the same for bundle and product purchases")
      end
    end

    context "product purchase is bundle purchase" do
      before do
        bundle_product_purchase.product_purchase.update!(link: create(:product, :bundle, user: bundle_product_purchase.product_purchase.seller))
      end

      it "adds an error" do
        expect(bundle_product_purchase).to_not be_valid
        expect(bundle_product_purchase.errors.full_messages.first).to eq("Product purchase cannot be a bundle purchase")
      end
    end
  end
end
