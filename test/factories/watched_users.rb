# frozen_string_literal: true

FactoryBot.define do
  factory :watched_user do
    user
    revenue_threshold_cents { 20_000 }
    notes { "Watching for repeat suspicious activity" }
  end
end
