# frozen_string_literal: true

FactoryBot.define do
  factory :product_cached_value do
    product

    trait :expired do
      expired { true }
    end
  end
end
