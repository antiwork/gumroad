# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_presentment do
    purchase
    charge_presentment
    processor { StripeChargeProcessor.charge_processor_id }
    presentment_currency { Currency::CAD }
    presentment_price_cents { 12_00 }
    presentment_tip_cents { 0 }
    presentment_seller_tax_cents { 0 }
    presentment_gumroad_tax_cents { 1_50 }
    presentment_shipping_cents { 0 }
    presentment_total_cents { 13_50 }
    presentment_gumroad_amount_cents { 1_35 }
  end
end
