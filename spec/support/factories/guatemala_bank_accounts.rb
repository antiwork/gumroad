# frozen_string_literal: true

FactoryBot.define do
  factory :guatemala_bank_account do
    user
    account_number { "GT20AGRO00000000001234567890" }
    account_number_last_four { "7890" }
    bank_code { "AAAAGTGCXYZ" }
    account_holder_full_name { "Guatemala Creator" }
  end
end
