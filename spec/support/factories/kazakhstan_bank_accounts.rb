# frozen_string_literal: true

FactoryBot.define do
  factory :kazakhstan_bank_account do
    user
    account_number { "KZ221251234567890123" }
    account_number_last_four { "0123" }
    bank_code { "AAAAKZKZXXX" }
    account_holder_full_name { "Kaz creator" }
  end
end
