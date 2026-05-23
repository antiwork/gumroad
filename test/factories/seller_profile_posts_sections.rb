# frozen_string_literal: true

FactoryBot.define do
  factory :seller_profile_posts_section do
    seller { create(:user) }
    shown_posts { [] }
  end
end
