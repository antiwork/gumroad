# frozen_string_literal: true

FactoryBot.define do
  factory :nigeria_bank_account do
    user
    account_number { "1111111112" }
    account_number_last_four { "1112" }
    bank_code { "AAAANGLAXXX" }
    account_holder_full_name { "Nigerian Creator I" }
  end
end
