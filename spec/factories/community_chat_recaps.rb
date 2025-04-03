# frozen_string_literal: true

FactoryBot.define do
  factory :community_chat_recap do
    association :community_chat_recap_run
    association :community
    association :seller, factory: :user
    summarized_message_count { 10 }
    input_token_count { 1000 }
    output_token_count { 200 }
    status { "pending" }

    trait :finished do
      status { "finished" }
    end

    trait :failed do
      status { "failed" }
    end

    trait :without_community do
      community { nil }
    end
  end
end
