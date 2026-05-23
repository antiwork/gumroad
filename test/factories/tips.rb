# frozen_string_literal: true

FactoryBot.define do
  factory :tip do
    value_cents { 100 }
    purchase
  end
end
