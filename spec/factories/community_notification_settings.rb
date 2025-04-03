# frozen_string_literal: true

FactoryBot.define do
  factory :community_notification_setting do
    association :user
    association :seller, factory: :user
    recap_frequency { "daily" }

    trait :weekly_recap do
      recap_frequency { "weekly" }
    end

    trait :no_recap do
      recap_frequency { nil }
    end
  end
end
