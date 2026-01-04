# frozen_string_literal: true

FactoryBot.define do
  factory :gibraltar_bank_account do
    user
    account_number { "01234567" }
    account_number_last_four { "4567" }
    sort_code { "12-34-56" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
