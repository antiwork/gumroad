# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_refund_policy do
    purchase
    title { "30-day money back guarantee" }
    fine_print { "This is a purchase-level refund policy" }
    max_refund_period_in_days { 30 }
  end
end
