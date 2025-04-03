# frozen_string_literal: true

FactoryBot.define do
  factory :cambodia_bank_account do
    user
    bank_code { "AAAAKHKHXXX" }
    account_number { "000123456789" }
    account_number_last_four { "6789" }
    account_holder_full_name { "Cambodian Creator" }
  end
end
