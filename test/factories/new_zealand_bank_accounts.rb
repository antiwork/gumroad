# frozen_string_literal: true

FactoryBot.define do
  factory :new_zealand_bank_account do
    user
    account_number { "1100000000000010" }
    account_number_last_four { "0010" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
