# frozen_string_literal: true

FactoryBot.define do
  factory :seller_profile_featured_product_section do
    seller { create(:user) }
  end
end
