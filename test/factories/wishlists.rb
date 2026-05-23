# frozen_string_literal: true

FactoryBot.define do
  factory :wishlist do
    user
    sequence(:name) { |n| "Wishlist #{n}" }
  end
end
