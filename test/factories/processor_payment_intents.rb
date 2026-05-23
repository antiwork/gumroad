# frozen_string_literal: true

FactoryBot.define do
  factory :processor_payment_intent do
    purchase
    intent_id { SecureRandom.uuid }
  end
end
