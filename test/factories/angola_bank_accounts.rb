# frozen_string_literal: true

FactoryBot.define do
  factory :angola_bank_account do
    user
    account_number { "AO06004400006729503010102" }
    account_number_last_four { "0102" }
    bank_code { "AAAAAOAOXXX" }
    account_holder_full_name { "Angola Creator" }
  end
end
