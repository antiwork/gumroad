# frozen_string_literal: true

FactoryBot.define do
  factory :price do
    association :link, factory: :product
    price_cents { 100 }
    currency { "usd" }

    factory :fixed_duration_price do
      recurrence { "monthly" }
      fixed_duration_months { 12 }
    end

    factory :recurring_price do
      recurrence { "monthly" }
    end
  end
end
