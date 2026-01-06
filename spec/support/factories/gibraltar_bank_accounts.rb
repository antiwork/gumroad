# frozen_string_literal: true

FactoryBot.define do
  factory :gibraltar_bank_account do
    user
    account_number { "00012345" }
    account_number_last_four { "2345" }
    sort_code { "10-88-00" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
