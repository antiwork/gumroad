# frozen_string_literal: true

FactoryBot.define do
  factory :kuwait_bank_account do
    user
    bank_code { "AAAAKWKWXYZ" }
    account_number { "KW81CBKU0000000000001234560101" }
    account_number_last_four { "0101" }
    account_holder_full_name { "Kuwaiti Creator" }
  end
end
