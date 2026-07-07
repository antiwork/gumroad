# frozen_string_literal: true

FactoryBot.define do
  factory :ai_conversation do
    association :seller, factory: :user
    title { "How are my sales doing?" }
  end

  factory :ai_message do
    ai_conversation
    role { "user" }
    content { "How are my sales doing?" }
  end
end
