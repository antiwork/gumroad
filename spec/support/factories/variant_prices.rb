# frozen_string_literal: true

FactoryBot.define do
  factory :variant_price do
    variant
    price_cents { 100 }
    currency { "usd" }
    recurrence { "monthly" }

    factory :pwyw_recurring_variant_price do
      suggested_price_cents { 200 }

      after(:create) do |price|
        price.variant.update!(customizable_price: true)
      end
    end
  end
end
