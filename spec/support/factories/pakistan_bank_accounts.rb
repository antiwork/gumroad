# frozen_string_literal: true

FactoryBot.define do
  factory :pakistan_bank_account do
    user
    account_number { "PK36SCBL0000001123456702" }
    account_number_last_four { "6702" }
    bank_code { "AAAAPKKAXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
