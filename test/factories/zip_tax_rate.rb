# frozen_string_literal: true

FactoryBot.define do
  factory :zip_tax_rate do
    combined_rate { "0.1100000" }
    county_rate { "0.0100000" }
    special_rate { "0.0300000" }
    state_rate { "0.0500000" }
    city_rate { "0.0200000" }
    state { "NY" }
    zip_code { "10087" }
    country { "US" }
    is_seller_responsible { 1 }
    is_epublication_rate { 0 }
  end
end
