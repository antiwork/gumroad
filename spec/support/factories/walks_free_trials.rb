# frozen_string_literal: true

FactoryBot.define do
  factory :walks_free_trial do
    walks_app_attest_key
    consumed_at { Time.current }
  end
end
