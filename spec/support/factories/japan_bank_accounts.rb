# frozen_string_literal: true

FactoryBot.define do
  factory :japan_bank_account do
    user
    account_number { "0001234" }
    account_number_last_four { "1234" }
    bank_code { "1100" }
    branch_code { "000" }
    account_holder_full_name { "Japanese Creator" }
  end
end
