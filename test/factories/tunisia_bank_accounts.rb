# frozen_string_literal: true

FactoryBot.define do
  factory :tunisia_bank_account do
    user
    account_number { "TN5904018104004942712345" }
    account_number_last_four { "2345" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
