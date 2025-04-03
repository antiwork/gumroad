# frozen_string_literal: true

FactoryBot.define do
  factory :card_bank_account do
    user
    credit_card { create(:credit_card, chargeable: create(:cc_token_chargeable, card: CardParamsSpecHelper.success_debit_visa)) }
  end
end
