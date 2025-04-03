# frozen_string_literal: true

FactoryBot.define do
  factory :macao_bank_account do
    user
    account_number { "0000000001234567897" }
    account_number_last_four { "7897" }
    bank_code { "AAAAMOMXXXX" }
    account_holder_full_name { "Macao Creator" }
  end
end
