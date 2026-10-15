# frozen_string_literal: true

FactoryBot.define do
  factory :oauth_device_authorization do
    association :oauth_application
    scopes { "view_profile" }
    status { OauthDeviceAuthorization::STATUS_PENDING }
    expires_at { OauthDeviceAuthorization::EXPIRES_IN.from_now }
    created_ip_address { "203.0.113.1" }
    created_user_agent { "RSpec" }

    transient do
      sequence(:device_code) { |n| "device-code-#{n}" }
      sequence(:user_code) { |n| "GRD-#{n.to_s.rjust(8, "0").scan(/.{1,4}/).join("-")}" }
    end

    device_code_digest { OauthDeviceAuthorization.digest(device_code) }
    user_code_digest { OauthDeviceAuthorization.digest(OauthDeviceAuthorization.normalize_user_code(user_code)) }
  end
end
