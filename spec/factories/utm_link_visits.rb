# frozen_string_literal: true

FactoryBot.define do
  factory :utm_link_visit do
    association :utm_link
    user { nil }
    ip_address { "127.0.0.1" }
    browser_guid { SecureRandom.uuid }
    country_code { "US" }
    referrer { "https://twitter.com" }
    user_agent { "Mozilla/5.0" }
  end
end
