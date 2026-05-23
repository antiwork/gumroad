# frozen_string_literal: true

FactoryBot.define do
  factory :backtax_collection do
    user
    backtax_agreement
    amount_cents { 1000 }
    amount_cents_usd { 1000 }
    currency { "usd" }
    stripe_transfer_id { "tr_2M97Bm9e1RjUNIyY0WbsSZGp" }
  end
end
