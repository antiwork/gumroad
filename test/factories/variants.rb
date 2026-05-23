# frozen_string_literal: true

FactoryBot.define do
  factory :variant do
    variant_category
    price_difference_cents { 0 }
    name { Faker::Subscription.plan }

    transient do
      active_integrations { [] }
    end

    trait :with_product_file do
      after(:create) do |variant|
        variant.product_files << create(:product_file, link: variant.variant_category.link)
      end
    end

    after(:create) { |variant, evaluator| variant.active_integrations |= evaluator.active_integrations }
  end
end
