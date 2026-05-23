# frozen_string_literal: true

require "test_helper"

class BundleProductPurchaseTest < ActiveSupport::TestCase
  self.described_class = BundleProductPurchase



  context_ BundleProductPurchase do
  context_ "validations" do
      let(:bundle_product_purchase) { create(:bundle_product_purchase) }

  context_ "bundle product purchase is valid" do
  test "doesn't add an error" do
          expect(bundle_product_purchase).to be_valid
        end
      end

  context_ "bundle purchase and product purchase have different sellers" do
        before do
          product = create(:product)
          bundle_product_purchase.product_purchase.update!(seller: product.user, link: product)
        end

  test "adds an error" do
          expect(bundle_product_purchase).not_to be_valid
          expect(bundle_product_purchase.errors.full_messages.first).to eq("Seller must be the same for bundle and product purchases")
        end
      end

  context_ "product purchase is bundle purchase" do
        before do
          bundle_product_purchase.product_purchase.update!(link: create(:product, :bundle, user: bundle_product_purchase.product_purchase.seller))
        end

  test "adds an error" do
          expect(bundle_product_purchase).not_to be_valid
          expect(bundle_product_purchase.errors.full_messages.first).to eq("Product purchase cannot be a bundle purchase")
        end
      end
    end
  end
end
