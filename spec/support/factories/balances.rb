# frozen_string_literal: true

FactoryBot.define do
  factory :balance do
    user
    merchant_account { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }
    date { Date.today }
    currency { Currency::USD }
    amount_cents { 10_00 }
    holding_currency { currency }
    holding_amount_cents { amount_cents }
    state { "unpaid" }
  end
end
