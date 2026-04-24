# frozen_string_literal: true

FactoryBot.define do
  factory :billing_detail do
    association :purchaser, factory: :user
    full_name { "John Doe" }
    business_name { "Acme Corporation" }
    business_id { "DE123456789" }
    street_address { "123 Main Street" }
    city { "Berlin" }
    zip_code { "10115" }
    country_code { "DE" }
    additional_notes { nil }

    trait :us do
      state { "CA" }
      country_code { "US" }
      zip_code { "94107" }
      city { "San Francisco" }
    end

    trait :without_business do
      business_name { nil }
      business_id { nil }
    end

    trait :no_auto_email do
      auto_email_invoice_enabled { false }
    end
  end
end
