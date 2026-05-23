# frozen_string_literal: true

FactoryBot.define do
  factory :tanzania_bank_account do
    user
    account_number { "0000123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAATZTXXXX" }
    account_holder_full_name { "Tanzanian Creator I" }
  end
end
