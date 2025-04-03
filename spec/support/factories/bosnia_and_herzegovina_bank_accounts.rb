# frozen_string_literal: true

FactoryBot.define do
  factory :bosnia_and_herzegovina_bank_account do
    user
    account_number { "BA095520001234567812" }
    account_number_last_four { "7812" }
    bank_code { "AAAABABAXXX" }
    account_holder_full_name { "Bosnia and Herzegovina Creator I" }
  end
end
