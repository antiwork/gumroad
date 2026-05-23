# frozen_string_literal: true

FactoryBot.define do
  factory :cart do
    association :user, factory: :user
    browser_guid { SecureRandom.uuid }
    ip_address { Faker::Internet.ip_v4_address }

    trait :guest do
      user { nil }
    end
  end
end
