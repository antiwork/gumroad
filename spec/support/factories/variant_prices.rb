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
    factory :fixed_duration_variant_price do
      fixed_duration_months { 12 }
    end

    factory :tier_specific_duration_variant_price do
      transient do
        duration_months { 12 }
        tier_name { "Premium" }
      end

      fixed_duration_months { duration_months }

      after(:create) do |price, evaluator|
        price.variant.update!(name: evaluator.tier_name)
      end
    end
  end
end
