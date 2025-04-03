# frozen_string_literal: true

FactoryBot.define do
  factory :affiliate_credit do
    basis_points { 300 }
    association :affiliate_user
    association :affiliate, factory: :direct_affiliate
    purchase { create(:purchase) }
    seller { purchase.seller }
    link { purchase.link }
  end
end
