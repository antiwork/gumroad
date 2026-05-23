# frozen_string_literal: true

FactoryBot.define do
  factory :canadian_bank_account do
    user
    account_number { "1234567" }
    transit_number { "12345" }
    institution_number { "123" }
    account_number_last_four { "4567" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
