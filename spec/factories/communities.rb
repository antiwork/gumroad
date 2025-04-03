# frozen_string_literal: true

FactoryBot.define do
  factory :community do
    association :seller, factory: :user
    resource { association :product }
  end
end
