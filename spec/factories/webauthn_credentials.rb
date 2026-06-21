# frozen_string_literal: true

FactoryBot.define do
  factory :webauthn_credential do
    association :user
    webauthn_id { SecureRandom.urlsafe_base64(32) }
    public_key { SecureRandom.urlsafe_base64(128) }
    sign_count { 0 }
    nickname { "Passkey" }
  end
end
