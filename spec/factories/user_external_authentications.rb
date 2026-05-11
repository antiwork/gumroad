# frozen_string_literal: true

FactoryBot.define do
  factory :user_external_authentication do
    user
    provider { "apple" }
    sequence(:uid) { "uid-#{_1}" }
  end
end
