# frozen_string_literal: true

FactoryBot.define do
  factory :argentina_bank_account do
    user
    account_number { "0110000600000000000000" }
    account_number_last_four { "0000" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
