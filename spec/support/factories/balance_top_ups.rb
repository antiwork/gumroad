# frozen_string_literal: true

FactoryBot.define do
  factory :balance_top_up do
    user
    amount_cents { 1000 }
    state { "pending" }
    processor { StripeChargeProcessor.charge_processor_id }

    before(:create) do |balance_top_up, _evaluator|
      unless balance_top_up.credit_card_id
        credit_card = CreditCard.create!(
          card_type: "visa",
          visual: "4242",
          expiry_month: 12,
          expiry_year: Date.current.year + 2,
          stripe_customer_id: "cus_test_#{SecureRandom.hex(8)}",
          stripe_fingerprint: "fp_test_#{SecureRandom.hex(8)}",
          charge_processor_id: StripeChargeProcessor.charge_processor_id
        )
        balance_top_up.credit_card = credit_card
      end
    end

    trait :processing do
      state { "processing" }
    end

    trait :successful do
      state { "successful" }
      processor_transaction_id { "ch_#{SecureRandom.hex(12)}" }
      processor_payment_intent_id { "pi_#{SecureRandom.hex(12)}" }
    end

    trait :failed do
      state { "failed" }
      error_message { "Card declined" }
    end
  end
end
