# frozen_string_literal: true

FactoryBot.define do
  factory :serbia_bank_account do
    user
    account_number { "RS35105008123123123173" }
    account_number_last_four { "3173" }
    bank_code { "TESTSERBXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
