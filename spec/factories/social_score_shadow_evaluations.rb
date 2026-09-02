# frozen_string_literal: true

FactoryBot.define do
  factory :social_score_shadow_evaluation do
    user
    evaluated_on { Date.current }
    hold_source { "risk_state_not_reviewed" }
    unpaid_balance_cents { 10_000 }
    score { 0 }
    would_have_released { false }
  end
end
