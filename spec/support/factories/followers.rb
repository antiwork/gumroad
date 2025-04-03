# frozen_string_literal: true

FactoryBot.define do
  factory :follower do
    user
    email { generate :email }

    factory :active_follower do
      confirmed_at { Time.current }
    end

    factory :deleted_follower do
      deleted_at { Time.current }
    end
  end
end
