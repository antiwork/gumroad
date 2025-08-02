# frozen_string_literal: true

FactoryBot.define do
  factory :direct_affiliate do
    association :affiliate_user, factory: :affiliate_user
    association :seller, factory: :user
    affiliate_basis_points { 300 }
    send_posts { true }
    status { 'approved' } # Default to approved for existing tests

    trait :pending do
      status { 'pending' }
    end

    trait :denied do
      status { 'denied' }
    end
  end
end
