# frozen_string_literal: true

FactoryBot.define do
  factory :moldova_bank_account do
    association :user
    bank_code { "AAAAMDMDXXX" }
    account_number { "MD07AG123456789012345678" }
    account_number_last_four { "5678" }
    account_holder_full_name { "Chuck Bartowski" }
  end
end
