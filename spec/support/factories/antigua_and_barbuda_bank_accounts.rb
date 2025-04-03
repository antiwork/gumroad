# frozen_string_literal: true

FactoryBot.define do
  factory :antigua_and_barbuda_bank_account do
    user
    account_number { "000123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAAAGAGXYZ" }
    account_holder_full_name { "Antigua and Barbuda Creator I" }
  end
end
