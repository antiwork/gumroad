# frozen_string_literal: true

FactoryBot.define do
  factory :armenia_bank_account do
    user
    bank_code { "AAAAAMNNXXX" }
    account_number { "00001234567" }
    account_number_last_four { "4567" }
    account_holder_full_name { "Armenia creator" }
  end
end
