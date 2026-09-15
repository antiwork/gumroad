# frozen_string_literal: true

FactoryBot.define do
  factory :social_connect_verification do
    user
    platform { "twitter" }
    sequence(:uid) { |n| "uid-#{n}" }
    sequence(:handle) { |n| "handle#{n}" }
    account_created_at { 5.years.ago }
    follower_count { 1_000 }
    post_count { 250 }
    last_posted_at { 1.week.ago }
    last_verified_at { Time.current }
  end
end
