# frozen_string_literal: true

FactoryBot.define do
  factory :shipping_destination do
    country_code { Product::Shipping::ELSEWHERE }
    one_item_rate_cents { 0 }
    multiple_items_rate_cents { 0 }
  end
end
