# frozen_string_literal: true

FactoryBot.define do
  factory :device do
    token { generate(:token) }
    app_version { "1.0.0" }
    device_type { "ios" }
    app_type { Device::APP_TYPES[:creator] }
    user

    factory :android_device do
      device_type { "android" }
    end
  end
end
