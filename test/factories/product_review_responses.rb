# frozen_string_literal: true

FactoryBot.define do
  factory :product_review_response do
    product_review
    user { product_review.purchase.seller }
    message { Faker::Lorem.paragraph }
  end
end
