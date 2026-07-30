# frozen_string_literal: true

FactoryBot.define do
  factory :guardian do
    user
    first_name { "Ellie" }
    last_name { "Bartowski" }
    email { "guardian@example.com" }
    phone { "0000000000" }
    date_of_birth { Date.new(1975, 3, 4) }
    street_address { "address_full_match" }
    city { "San Francisco" }
    state { "California" }
    zip_code { "94107" }
    country { "United States" }
    individual_tax_id { "000000000" }
    stripe_tos_accepted { true }
  end
end
