# frozen_string_literal: true

FactoryBot.define do
  factory :scheduled_payout do
    user
    action { "payout" }
    processor { user.current_payout_processor }
    delay_days { 21 }
    scheduled_at { 21.days.from_now }
    status { "pending" }
    payout_amount_cents { 10_000 }
  end
end
