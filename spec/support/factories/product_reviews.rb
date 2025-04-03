# frozen_string_literal: true

FactoryBot.define do
  factory :product_review do
    purchase
    link { purchase.try(:link) }
    rating { 1 }
    message { Faker::Lorem.paragraph }
  end
end
