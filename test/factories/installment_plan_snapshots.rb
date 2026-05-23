# frozen_string_literal: true

FactoryBot.define do
  factory :installment_plan_snapshot do
    payment_option
    number_of_installments { 3 }
    recurrence { "monthly" }
    total_price_cents { 14700 }
  end
end
