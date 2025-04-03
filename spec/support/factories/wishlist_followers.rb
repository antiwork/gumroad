# frozen_string_literal: true

FactoryBot.define do
  factory :wishlist_follower do
    wishlist
    association :follower_user, factory: :user
  end
end
