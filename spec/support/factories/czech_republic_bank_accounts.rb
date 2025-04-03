# frozen_string_literal: true

FactoryBot.define do
  factory :czech_republic_bank_account do
    user
    account_number { "CZ6508000000192000145399" }
    account_number_last_four { "3000" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
