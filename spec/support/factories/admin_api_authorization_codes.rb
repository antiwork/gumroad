# frozen_string_literal: true

FactoryBot.define do
  factory :admin_api_authorization_code do
    association :actor_user, factory: :admin_user
    expires_at { 60.seconds.from_now }

    transient do
      plaintext_code { AdminApiToken.generate_plaintext_token }
      code_verifier { "test-code-verifier" }
    end

    code_hash { AdminApiAuthorizationCode.hash_code(plaintext_code) }
    code_challenge { AdminApiAuthorizationCode.code_challenge_for(code_verifier) }
  end
end
