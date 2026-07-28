# frozen_string_literal: true

FactoryBot.define do
  factory :subscription_presentment do
    subscription
    processor { StripeChargeProcessor.charge_processor_id }
    presentment_currency { Currency::EUR }
    presentment_price_cents { 9_99 }
    signup_currency_units_per_usd { BigDecimal("0.89") }
    effective_from { Time.current }
  end
end
