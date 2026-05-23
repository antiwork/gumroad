# frozen_string_literal: true

FactoryBot.define do
  factory :sku do
    association :link, factory: :product
    price_difference_cents { 0 }
    name { "Large" }
  end
end
