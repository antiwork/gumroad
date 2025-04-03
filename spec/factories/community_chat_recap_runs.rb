# frozen_string_literal: true

FactoryBot.define do
  factory :community_chat_recap_run do
    recap_frequency { "daily" }
    from_date { (Time.current - rand(1..1000).days).beginning_of_day }
    to_date { (Time.current - rand(1..1000).days).end_of_day }
    recaps_count { 0 }

    trait :weekly do
      recap_frequency { "weekly" }
      from_date { (Date.yesterday - 6.days).beginning_of_day }
      to_date { Date.yesterday.end_of_day }
    end

    trait :finished do
      finished_at { Time.current }
    end

    trait :notified do
      notified_at { Time.current }
    end
  end
end
