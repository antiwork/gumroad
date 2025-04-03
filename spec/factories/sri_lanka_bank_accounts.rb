# frozen_string_literal: true

FactoryBot.define do
  factory :sri_lanka_bank_account do
    user
    bank_code { "AAAALKLXXXX" }
    branch_code { "7010999" }
    account_number { "0000012345" }
    account_number_last_four { "2345" }
    account_holder_full_name { "Sri Lankan Creator" }
  end
end
