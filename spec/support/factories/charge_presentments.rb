# frozen_string_literal: true

FactoryBot.define do
  factory :charge_presentment do
    charge
    processor { StripeChargeProcessor.charge_processor_id }
    presentment_currency { Currency::CAD }
    presentment_total_cents { 13_50 }
    presentment_gumroad_amount_cents { 1_35 }
    stripe_fx_quote_id { "fxq_#{SecureRandom.hex}" }
    stripe_fx_quote_expires_at { 30.minutes.from_now }
    fx_rate { BigDecimal("0.740000000000000") }
  end
end
