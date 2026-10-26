# frozen_string_literal: true

FactoryBot.define do
  factory :product_sales_hold do
    product
    held_by { association :admin_user }
  end
end
