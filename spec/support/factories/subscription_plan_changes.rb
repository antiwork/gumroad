# frozen_string_literal: true

FactoryBot.define do
  factory :subscription_plan_change do
    subscription
    association :tier, factory: :variant
    recurrence { "monthly" }
    perceived_price_cents { 500 }
  end
end
