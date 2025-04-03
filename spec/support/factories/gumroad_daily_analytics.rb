# frozen_string_literal: true

FactoryBot.define do
  factory :gumroad_daily_analytic do
    period_ended_at { "2023-02-03 17:07:30" }
    gumroad_price_cents { 1500 }
    gumroad_fee_cents { 150 }
    creators_with_sales { 45 }
    gumroad_discover_price_cents { 700 }
  end
end
