# frozen_string_literal: true

FactoryBot.define do
  factory :wishlist_product do
    wishlist
    product

    trait :with_quantity do
      product { create(:physical_product) }
      quantity { 5 }
    end

    trait :with_recurring_variant do
      product { create(:membership_product_with_preset_tiered_pricing) }
      variant { product.alive_variants.first }
      recurrence { "monthly" }
    end
  end
end
