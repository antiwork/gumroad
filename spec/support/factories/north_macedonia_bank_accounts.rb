# frozen_string_literal: true

FactoryBot.define do
  factory :north_macedonia_bank_account do
    user
    account_number { "MK49250120000058907" }
    account_number_last_four { "8907" }
    account_holder_full_name { "Gumbot Gumstein I" }
    bank_code { "AAAAMK2XXXX" }
  end
end
