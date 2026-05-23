# frozen_string_literal: true

FactoryBot.define do
  factory :korea_bank_account do
    user
    account_number { "000123456789" }
    bank_number { "SGSEKRSLXXX" }
    account_number_last_four { "6789" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
