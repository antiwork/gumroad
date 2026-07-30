# frozen_string_literal: true

FactoryBot.define do
  factory :bundle_product_purchase do
    bundle_purchase { create(:purchase) }
    # Purchase::CreateBundleProductPurchaseService copies the buyer's email onto the per-product
    # record, and `Purchase#receipt_purchase` relies on the two agreeing.
    product_purchase { create(:purchase, link: create(:product, user: bundle_purchase.seller), seller: bundle_purchase.seller, email: bundle_purchase.email) }
  end
end
