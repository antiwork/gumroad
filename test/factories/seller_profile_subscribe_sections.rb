# frozen_string_literal: true

FactoryBot.define do
  factory :seller_profile_subscribe_section do
    seller { create(:user) }
    header { "Subscribe to me!" }
    button_label { "Subscribe" }
  end
end
