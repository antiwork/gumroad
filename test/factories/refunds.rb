# frozen_string_literal: true

FactoryBot.define do
  factory :refund do
    purchase
    refunding_user_id { create(:user).id }
    total_transaction_cents { purchase.total_transaction_cents }
    amount_cents { purchase.price_cents }
    creator_tax_cents { purchase.tax_cents }
    gumroad_tax_cents { purchase.gumroad_tax_cents }
  end
end
