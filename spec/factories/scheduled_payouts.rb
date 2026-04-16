# frozen_string_literal: true

FactoryBot.define do
  factory :scheduled_payout do
    user
    action { "payout" }
    delay_days { 21 }
    scheduled_at { 21.days.from_now }
    status { "pending" }
  end
end
