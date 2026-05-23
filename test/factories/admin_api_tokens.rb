# frozen_string_literal: true

FactoryBot.define do
  factory :admin_api_token do
    association :actor_user, factory: :admin_user
    token_hash { AdminApiToken.hash_token(SecureRandom.uuid) }
  end
end
