# frozen_string_literal: true

FactoryBot.define do
  factory :brunei_bank_account do
    user
    account_number { "0000123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAABNBBXXX" }
    account_holder_full_name { "Brunei Creator" }
  end
end
