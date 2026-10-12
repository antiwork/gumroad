# frozen_string_literal: true

FactoryBot.define do
  factory :credit_card do
    transient do
      chargeable { build(:chargeable) }
      user { nil }
    end
    initialize_with do
      CreditCard.create(chargeable, nil, user)
    end
  end

  # An Indian Stripe card persisted straight from its stored ids, for specs that stub the mandate and
  # setup-intent lookups instead of going through a chargeable.
  factory :indian_stripe_credit_card, class: "CreditCard" do
    transient do
      stripe_setup_intent_id { nil }
    end

    charge_processor_id { StripeChargeProcessor.charge_processor_id }
    stripe_customer_id { "cus_pending" }
    processor_payment_method_id { "pm_pending" }
    stripe_fingerprint { "fingerprint_pending" }
    visual { "**** **** **** 4242" }
    card_type { CardType::VISA }
    card_country { Compliance::Countries::IND.alpha2 }
    expiry_month { 12 }
    expiry_year { 2030 }

    after(:build) do |card, evaluator|
      card.json_data = { stripe_setup_intent_id: evaluator.stripe_setup_intent_id } if evaluator.stripe_setup_intent_id.present?
    end
  end
end
