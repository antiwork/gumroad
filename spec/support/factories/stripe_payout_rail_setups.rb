# frozen_string_literal: true

FactoryBot.define do
  factory :stripe_payout_rail_setup do
    user
    bank_account { association :ach_account, user:, deleted_at: Time.current }

    trait :prepared do
      state { StripePayoutRailSetup::PREPARED }
      merchant_account { association :merchant_account, user:, charge_processor_alive_at: nil, country: "US" }
      prepared_at { Time.current }
    end
  end

  # A US debit card persisted from synthetic stored ids, for rail-setup specs that stub the card
  # tokenization boundary instead of creating a Stripe customer.
  factory :us_debit_stripe_credit_card, class: "CreditCard" do
    charge_processor_id { StripeChargeProcessor.charge_processor_id }
    stripe_customer_id { "cus_synthetic_debit" }
    processor_payment_method_id { "pm_synthetic_debit" }
    sequence(:stripe_fingerprint) { |n| "fingerprint_synthetic_debit_#{n}" }
    visual { "**** **** **** 5556" }
    card_type { CardType::VISA }
    card_country { Compliance::Countries::USA.alpha2 }
    funding_type { ChargeableFundingType::DEBIT }
    expiry_month { 12 }
    expiry_year { 2031 }
  end
end
