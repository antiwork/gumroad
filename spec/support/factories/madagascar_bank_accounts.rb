# frozen_string_literal: true

FactoryBot.define do
  factory :madagascar_bank_account do
    user
    account_number { "MG4800005000011234567890123" }
    account_number_last_four { "0123" }
    bank_code { "AAAAMGMGXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
