# frozen_string_literal: true

FactoryBot.define do
  factory :black_recurring_service do
    user
    state { "active" }
    price_cents { 10_00 }
    recurrence { :monthly }
  end
end
