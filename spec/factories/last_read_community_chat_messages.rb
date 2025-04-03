# frozen_string_literal: true

FactoryBot.define do
  factory :last_read_community_chat_message do
    association :user
    association :community
    association :community_chat_message
  end
end
