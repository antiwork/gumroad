# frozen_string_literal: true

FactoryBot.define do
  factory :creator_analytics_churn_cache do
    user
    date { Date.current }
    customer_churn_rate { 4.55 }
    churned_subscribers { 5 }
    churned_mrr_cents { 50000 }
  end
end
