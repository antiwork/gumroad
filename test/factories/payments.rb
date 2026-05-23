# frozen_string_literal: true

FactoryBot.define do
  factory :payment do
    user
    state { "processing" }
    processor { PayoutProcessorType::PAYPAL }
    correlation_id { "12345" }
    amount_cents { 150 }
    payout_period_end_date { Date.yesterday }
  end

  factory :payment_unclaimed, parent: :payment do
    state { "unclaimed" }
  end

  factory :payment_completed, parent: :payment do
    state { "completed" }
    txn_id { "txn-id" }
    processor_fee_cents { 10 }
  end

  factory :payment_returned, parent: :payment_completed do
    state { "returned" }
  end

  factory :payment_reversed, parent: :payment_completed do
    state { "reversed" }
  end

  factory :payment_failed, parent: :payment_completed do
    state { "failed" }
  end
end
