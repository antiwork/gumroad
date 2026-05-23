# frozen_string_literal: true

FactoryBot.define do
  factory :rwanda_bank_account do
    user
    account_number { "000123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAARWRWXXX" }
    account_holder_full_name { "Rwandan Creator" }
  end
end
