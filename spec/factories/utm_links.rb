# frozen_string_literal: true

FactoryBot.define do
  factory :utm_link do
    association :seller, factory: :user
    sequence(:title) { |n| "UTM Link #{n}" }
    target_resource_type { :profile_page }
    sequence(:utm_campaign) { |n| "summer-sale-#{n}" }
    utm_medium { "social" }
    utm_source { "twitter" }
  end
end
