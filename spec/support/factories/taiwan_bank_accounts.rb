# frozen_string_literal: true

FactoryBot.define do
  factory :taiwan_bank_account do
    user
    account_number { "0001234567" }
    account_number_last_four { "4567" }
    bank_code { "AAAATWTXXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
