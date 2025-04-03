# frozen_string_literal: true

FactoryBot.define do
  factory :bhutan_bank_account do
    user
    account_number { "0000123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAABTBTXXX" }
    account_holder_full_name { "Bhutan Creator" }
  end
end
