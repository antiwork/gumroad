# frozen_string_literal: true

FactoryBot.define do
  factory :discount_collection do
    user
    sequence(:name) { |n| "Collection #{n}" }
    description { "A collection of discount codes" }
  end
end
