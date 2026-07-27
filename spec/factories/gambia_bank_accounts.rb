# frozen_string_literal: true

FactoryBot.define do
  factory :gambia_bank_account do
    user
    bank_code { "AAAAGMGMXYZ" }
    account_number { "000123000456000789" }
    account_number_last_four { "0789" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
