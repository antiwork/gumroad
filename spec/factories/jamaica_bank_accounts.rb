# frozen_string_literal: true

FactoryBot.define do
  factory :jamaica_bank_account do
    user
    bank_code { "111" }  # 3-digit bank code
    branch_code { "00000" }  # 5-digit branch code
    account_number { "000123456789" }  # 1-18 digit account number
    account_number_last_four { "6789" }
    account_holder_full_name { "John Doe" }
  end
end
