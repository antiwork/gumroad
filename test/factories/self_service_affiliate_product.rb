# frozen_string_literal: true

FactoryBot.define do
  factory :self_service_affiliate_product do
    association :seller, factory: :user
    product { create(:product, user: seller) }
    affiliate_basis_points { 500 }
  end
end
