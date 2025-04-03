# frozen_string_literal: true

FactoryBot.define do
  factory :audience_member do
    association :seller, factory: :user
    email { generate :email }
    details { {} }

    transient do
      purchases { nil }
      follower { nil }
      affiliates { nil }
    end

    after(:build) do |member, evaluator|
      if evaluator.purchases.present?
        member.details[:purchases] ||= []
        evaluator.purchases.each do |purchase|
          purchase[:id] ||= 1
          purchase[:product_id] ||= 1
          purchase[:price_cents] ||= 100
          purchase[:created_at] ||= 7.days.ago.iso8601
          purchase[:country] ||= "United States"
          member.details[:purchases] << purchase
        end
      end
      unless evaluator.follower.nil?
        follower = evaluator.follower
        follower[:id] ||= 1
        follower[:created_at] ||= 7.days.ago.iso8601
        member.details[:follower] = follower
      end
      if evaluator.affiliates.present?
        member.details[:affiliates] ||= []
        evaluator.affiliates.each do |affiliate|
          affiliate[:id] ||= 1
          affiliate[:product_id] ||= 1
          affiliate[:created_at] ||= 7.days.ago.iso8601
          member.details[:affiliates] << affiliate
        end
      end

      if member.details.blank?
        member.details = {
          follower: {
            id: 1,
            created_at: Time.current.iso8601
          }
        }
      end
    end
  end
end
