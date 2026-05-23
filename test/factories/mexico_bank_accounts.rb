# frozen_string_literal: true

FactoryBot.define do
  factory :mexico_bank_account do
    user
    account_number { "000000001234567897" }
    account_number_last_four { "7897" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
