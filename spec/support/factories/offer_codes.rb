# frozen_string_literal: true

FactoryBot.define do
  factory :offer_code do
    user
    products { [FactoryBot.create(:product, user:)] }
    code { "sxsw" }
    amount_cents { 1_00 }
    currency_type { user.currency_type }

    before(:create) do |offer_code|
      if offer_code.products.present?
        offer_code.user_id = offer_code.products.first.user_id
      end
    end

    factory :percentage_offer_code do
      products { [FactoryBot.create(:product, user:, price_cents: 2_00)] }
      amount_cents { nil }
      amount_percentage { 50 }
    end

    factory :universal_offer_code do
      universal { true }
      products { [] }
    end

    factory :cancellation_discount_offer_code do
      is_cancellation_discount { true }
      duration_in_billing_cycles { 3 }
      products { [FactoryBot.create(:membership_product_with_preset_tiered_pricing, user:)] }

      factory :fixed_cancellation_discount_offer_code do
        amount_cents { 100 }
        amount_percentage { nil }
      end

      factory :percentage_cancellation_discount_offer_code do
        amount_cents { nil }
        amount_percentage { 10 }
      end
    end
  end
end
