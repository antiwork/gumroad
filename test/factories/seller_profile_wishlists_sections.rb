# frozen_string_literal: true

FactoryBot.define do
  factory :seller_profile_wishlists_section do
    seller { create(:user) }
    shown_wishlists { [] }
  end
end
