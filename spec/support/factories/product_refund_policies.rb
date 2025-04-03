# frozen_string_literal: true

FactoryBot.define do
  factory :product_refund_policy do
    product
    seller { product.user }
    title { "Refund policy" }
    fine_print { "This is a product-level refund policy" }
  end
end
