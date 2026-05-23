# frozen_string_literal: true

FactoryBot.define do
  factory :product_refund_policy do
    product
    seller { product.user }
    max_refund_period_in_days { RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS }
    fine_print { "This is a product-level refund policy" }
  end
end
