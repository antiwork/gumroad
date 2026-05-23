# frozen_string_literal: true

FactoryBot.define do
  factory :bahamas_bank_account do
    user
    account_number { "0001234" }
    account_number_last_four { "1234" }
    bank_code { "AAAABSNSXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
