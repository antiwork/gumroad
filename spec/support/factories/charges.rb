# frozen_string_literal: true

FactoryBot.define do
  factory :charge do
    order { create(:order) }
    seller { create(:user) }
    processor { "stripe" }
    processor_transaction_id { "ch_#{SecureRandom.hex}" }
    payment_method_fingerprint { "pm_#{SecureRandom.hex}" }
    merchant_account { create(:merchant_account) }
    amount_cents { 10_00 }
    gumroad_amount_cents { 1_00 }
    processor_fee_cents { 20 }
    processor_fee_currency { "usd" }
    paypal_order_id { nil }
    stripe_payment_intent_id { "pi_#{SecureRandom.hex}" }
    stripe_setup_intent_id { "seti_#{SecureRandom.hex}" }
  end
end
