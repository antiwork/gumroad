# frozen_string_literal: true

FactoryBot.define do
  factory :bundle_product_purchase do
    bundle_purchase { create(:purchase) }
    product_purchase { create(:purchase, link: create(:product, user: bundle_purchase.seller), seller: bundle_purchase.seller) }
  end
end
