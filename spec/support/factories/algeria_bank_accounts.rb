# frozen_string_literal: true

FactoryBot.define do
  factory :algeria_bank_account do
    user
    account_number { "00001234567890123456" }
    account_number_last_four { "3456" }
    bank_code { "AAAADZDZXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
