# frozen_string_literal: true

FactoryBot.define do
  factory :san_marino_bank_account do
    user
    account_number { "SM86U0322509800000000270100" }
    account_number_last_four { "0100" }
    bank_code { "AAAASMSMXXX" }
    account_holder_full_name { "San Marino Creator" }
  end
end
