# frozen_string_literal: true

FactoryBot.define do
  factory :mongolia_bank_account do
    user
    bank_code { "AAAAMNUBXXX" }
    account_number { "0002222001" }
    account_number_last_four { "2001" }
    account_holder_full_name { "Mongolian Creator" }
  end
end
