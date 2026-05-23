# frozen_string_literal: true

FactoryBot.define do
  factory :seller_profile_rich_text_section do
    seller { create(:user) }
  end
end
