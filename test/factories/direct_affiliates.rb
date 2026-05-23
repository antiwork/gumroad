# frozen_string_literal: true

FactoryBot.define do
  factory :direct_affiliate do
    association :affiliate_user, factory: :affiliate_user
    association :seller, factory: :user
    affiliate_basis_points { 300 }
    send_posts { true }
  end
end
