# frozen_string_literal: true

FactoryBot.define do
  factory :resource_subscription do
    user
    oauth_application
    resource_name { "sale" }
    post_url { "http://example.com" }
  end
end
