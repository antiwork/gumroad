# frozen_string_literal: true

FactoryBot.define do
  factory :google_calendar_integration do
    calendar_id { "0" }
    calendar_summary { "Holidays" }
    access_token { "test_access_token" }
    refresh_token { "test_refresh_token" }
    email { "hi@gmail.com" }
  end
end
