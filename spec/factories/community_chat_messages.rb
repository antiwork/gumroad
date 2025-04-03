# frozen_string_literal: true

FactoryBot.define do
  factory :community_chat_message do
    association :community
    association :user
    content { "Hello, community!" }
  end
end
