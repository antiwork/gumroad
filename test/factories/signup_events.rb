# frozen_string_literal: true

FactoryBot.define do
  factory :signup_event do
    event_name { "signup" }
    from_profile { false }
    ip_country { "United States" }
    ip_state { "CA" }

    after(:build) do |event|
      event.referrer_domain = Referrer.extract_domain(event.referrer) if event.referrer.present?
      event.referrer_domain = REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS if event.was_product_recommended
    end
  end
end
