# frozen_string_literal: true

FactoryBot.define do
  factory :product_tagging do
    product { create(:product) }
    tag
  end
end
