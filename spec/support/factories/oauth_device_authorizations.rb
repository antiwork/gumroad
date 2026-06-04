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
      device_code { "device-code" }
      user_code { "GRD-ABCD-1234" }
    end

    device_code_digest { OauthDeviceAuthorization.digest(device_code) }
    user_code_digest { OauthDeviceAuthorization.digest(OauthDeviceAuthorization.normalize_user_code(user_code)) }
  end
end
