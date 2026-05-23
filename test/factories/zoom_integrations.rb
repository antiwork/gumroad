# frozen_string_literal: true

FactoryBot.define do
  factory :zoom_integration do
    user_id { "0" }
    email { "test@zoom.com" }
    access_token { "test_access_token" }
    refresh_token { "test_refresh_token" }
  end
end
