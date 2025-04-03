# frozen_string_literal: true

FactoryBot.define do
  factory :credit do
    user
    merchant_account
    amount_cents { 1_00 }
    crediting_user { create(:user) }
    balance
  end
end
