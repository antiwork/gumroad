# frozen_string_literal: true

FactoryBot.define do
  factory :seller_profile do
    seller { create(:user) }
  end
end
