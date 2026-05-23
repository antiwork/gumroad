# frozen_string_literal: true

FactoryBot.define do
  factory :indian_bank_account do
    user
    account_number { "000123456789" }
    account_number_last_four { "6789" }
    ifsc { "HDFC0004051" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
