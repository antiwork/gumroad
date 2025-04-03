# frozen_string_literal: true

FactoryBot.define do
  factory :uk_bank_account do
    user
    account_number { "1234567" }
    sort_code { "06-21-11" }
    account_number_last_four { "4567" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
