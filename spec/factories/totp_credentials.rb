# frozen_string_literal: true

FactoryBot.define do
  factory :totp_credential do
    association :user

    trait :confirmed do
      confirmed_at { Time.current }
    end

    trait :with_recovery_codes do
      confirmed
      after(:create) do |credential|
        credential.generate_recovery_codes
      end
    end
  end
end
