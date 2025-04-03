# frozen_string_literal: true

FactoryBot.define do
  factory :norway_bank_account do
    user
    account_number { "NO9386011117947" }
    account_number_last_four { "7947" }
    account_holder_full_name { "Norwegian Creator" }
  end
end
