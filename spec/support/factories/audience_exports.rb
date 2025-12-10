# frozen_string_literal: true

FactoryBot.define do
  factory :audience_export do
    association :seller, factory: :user
    association :recipient, factory: :user
    options { { followers: true } }
  end
end
