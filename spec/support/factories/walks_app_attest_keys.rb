# frozen_string_literal: true

FactoryBot.define do
  factory :walks_app_attest_key do
    sequence(:key_id) { |n| Base64.strict_encode64(OpenSSL::Digest::SHA256.digest("test-key-#{n}")) }
    public_key { OpenSSL::PKey::EC.generate("prime256v1").public_to_der }
    counter { 0 }
    environment { "development" }
    attested_at { Time.current }
  end
end
