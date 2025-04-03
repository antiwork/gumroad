# frozen_string_literal: true

FactoryBot.define do
  factory :price do
    association :link, factory: :product
    price_cents { 100 }
    currency { "usd" }
  end
end
