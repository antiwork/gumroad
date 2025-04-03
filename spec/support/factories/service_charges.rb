# frozen_string_literal: true

FactoryBot.define do
  factory :service_charge do
    user
    charge_cents { 1000 }
    charge_processor_fingerprint { "shfbeg5142fff" }
    charge_processor_transaction_id { "2763276372637263" }
    card_type { "visa" }
    card_visual { "**** **** **** 4062" }
    card_country { "US" }
    ip_address { generate :ip }
    browser_guid { generate :browser_guid }
    charge_processor_id do
      if chargeable
        chargeable.charge_processor_id
      else
        charge_processor_transaction_id ? StripeChargeProcessor.charge_processor_id : nil
      end
    end
    merchant_account { charge_processor_transaction_id ? MerchantAccount.gumroad(charge_processor_id) : nil }
    state { "successful" }
    succeeded_at { Time.current }

    factory :service_charge_in_progress do
      state { "in_progress" }
    end

    factory :failed_service_charge do
      state { "failed" }
    end

    factory :authorization_service_charge do
      state { "authorization_successful" }
    end

    factory :free_service_charge do
      charge_cents { 0 }
      charge_processor_id { nil }
      charge_processor_fingerprint { nil }
      charge_processor_transaction_id { nil }
      merchant_account { nil }
    end
  end
end
