# frozen_string_literal: true

FactoryBot.define do
  factory :mozambique_bank_account do
    user
    account_number { "001234567890123456789" }
    account_number_last_four { "6789" }
    bank_code { "AAAAMZMXXXX" }
    account_holder_full_name { "Mozambique Creator" }
  end
end
