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
    # The subdivision CODE, which is what the form's picker submits and what Stripe reads. Storing
    # the display name here would let specs pass on a value the real entry path never produces.
    state { "CA" }
    zip_code { "94107" }
    country { "United States" }
    individual_tax_id { "000000000" }
    stripe_tos_accepted { true }
    stripe_tos_accepted_at { Time.current }
    stripe_tos_ip { "1.2.3.4" }
  end
end
