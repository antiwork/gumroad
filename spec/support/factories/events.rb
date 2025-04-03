# frozen_string_literal: true

FactoryBot.define do
  factory :event do
    from_profile { false }
    ip_country { "United States" }
    ip_state { "CA" }

    after(:build) do |event|
      event.referrer_domain = Referrer.extract_domain(event.referrer) if event.referrer.present?
      event.referrer_domain = REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS if event.was_product_recommended
    end

    factory :purchase_event do
      event_name { "purchase" }
      purchase
      purchase_state { "successful" }

      after(:build) do |event|
        event.link_id ||= event.purchase.link.id
        event.price_cents ||= event.purchase.price_cents
      end
    end

    factory :service_charge_event do
      event_name { "service_charge" }
      service_charge
      purchase_state { "successful" }

      after(:build) do |event|
        event.price_cents ||= event.service_charge.charge_cents
      end
    end

    factory :post_view_event do
      event_name { "post_view" }
    end
  end
end
