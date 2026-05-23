# frozen_string_literal: true

FactoryBot.define do
  factory :bangladesh_bank_account do
    user
    account_number { "0000123456789" }
    account_number_last_four { "6789" }
    bank_code { "110000000" }
    account_holder_full_name { "Bangladesh Creator" }
  end
end
