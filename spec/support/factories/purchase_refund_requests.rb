# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_refund_request do
    purchase
    email { purchase.email }
    reason { "not_as_described" }
  end
end
