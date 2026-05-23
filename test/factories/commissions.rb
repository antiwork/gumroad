# frozen_string_literal: true

FactoryBot.define do
  factory :commission do
    status { "in_progress" }
    association :deposit_purchase, factory: :commission_deposit_purchase
  end
end
