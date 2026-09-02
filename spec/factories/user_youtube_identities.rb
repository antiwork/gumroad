# frozen_string_literal: true

FactoryBot.define do
  factory :user_youtube_identity do
    user
    sequence(:channel_id) { "UC#{_1}" }
    handle { "creator" }
  end
end
