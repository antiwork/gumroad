# frozen_string_literal: true

FactoryBot.define do
  factory :user_tiktok_identity do
    user
    sequence(:tiktok_open_id) { "tiktok-open-id-#{_1}" }
    handle { "gumroad" }
  end
end
