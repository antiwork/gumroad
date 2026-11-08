# frozen_string_literal: true

FactoryBot.define do
  factory :product_publish_schedule do
    association :product, factory: :product
    scheduled_by { product.user }
    publish_at { 1.hour.from_now }
    version { 1 }
    status { "scheduled" }
  end
end
