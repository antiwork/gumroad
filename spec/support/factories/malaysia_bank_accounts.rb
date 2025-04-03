# frozen_string_literal: true

FactoryBot.define do
  factory :malaysia_bank_account do
    user
    account_number { "000123456000" }
    account_number_last_four { "6000" }
    bank_code { "HBMBMYKL" }
    account_holder_full_name { "Malaysian Creator I" }
  end
end
