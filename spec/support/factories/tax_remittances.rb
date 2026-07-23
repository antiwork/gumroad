# frozen_string_literal: true

FactoryBot.define do
  factory :tax_remittance do
    authority { "HMRC" }
    jurisdiction { "GB" }
    period { "2026-Q1" }
    currency { "GBP" }
    usd_amount_cents { 25_333_498 }
    rail { "wise" }
    status { "draft" }

    trait :sent do
      status { "sent" }
      paid_at { Time.utc(2026, 4, 28) }
    end

    trait :completed do
      status { "completed" }
      paid_at { Time.utc(2026, 4, 28) }
    end

    trait :failed do
      status { "failed" }
    end
  end
end
