# frozen_string_literal: true

FactoryBot.define do
  factory :variant_category do
    association :link, factory: :product
    title { "Size" }
  end
end
