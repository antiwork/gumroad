# frozen_string_literal: true

FactoryBot.define do
  factory :qatar_bank_account do
    user
    account_number { "QA87CITI123456789012345678901" }
    account_number_last_four { "8901" }
    bank_code { "AAAAQAQAXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
