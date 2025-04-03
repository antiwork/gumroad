# frozen_string_literal: true

FactoryBot.define do
  factory :ethiopia_bank_account do
    user
    account_number { "0000000012345" }
    account_number_last_four { "2345" }
    bank_code { "AAAAETETXXX" }
    account_holder_full_name { "Ethiopia Creator" }
  end
end
