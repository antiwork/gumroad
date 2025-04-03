# frozen_string_literal: true

FactoryBot.define do
  factory :bundle_product do
    bundle { create(:product, :bundle) }
    product { create(:product, user: bundle.user) }
  end
end
