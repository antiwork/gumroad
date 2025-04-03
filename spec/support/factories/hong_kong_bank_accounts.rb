# frozen_string_literal: true

FactoryBot.define do
  factory :hong_kong_bank_account do
    user
    account_number { "000123456" }
    branch_code { "000" }
    bank_number { "110" }
    account_number_last_four { "3456" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
