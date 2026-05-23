# frozen_string_literal: true

FactoryBot.define do
  factory :early_fraud_warning do
    purchase
    processor_id { "issfr_0O3PbF9e1RjUNIyYjsCznU4B" }
    fraud_type { "made_with_stolen_card" }
    charge_risk_level { "normal" }
    actionable { true }
    processor_created_at { 1.hour.ago }
  end
end
