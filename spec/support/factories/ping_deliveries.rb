# frozen_string_literal: true

FactoryBot.define do
  factory :ping_delivery do
    association :user
    resource_name { ResourceSubscription::SALE_RESOURCE_NAME }
    post_url { "https://example.com/hook" }
    attempt { 1 }
    response_code { 200 }
    succeeded { true }
  end
end
