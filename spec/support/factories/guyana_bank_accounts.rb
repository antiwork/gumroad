# frozen_string_literal: true

FactoryBot.define do
  factory :guyana_bank_account do
    user
    account_number { "000123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAAGYGGXYZ" }
    account_holder_full_name { "Guyana Creator" }
  end
end
