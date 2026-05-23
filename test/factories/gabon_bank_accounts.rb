# frozen_string_literal: true

FactoryBot.define do
  factory :gabon_bank_account do
    user
    account_number { "00001234567890123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAAGAGAXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
