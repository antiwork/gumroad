# frozen_string_literal: true

FactoryBot.define do
  factory :product_review_stat do
    association :link, factory: :product
  end
end
