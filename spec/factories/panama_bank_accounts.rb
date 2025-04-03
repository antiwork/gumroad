# frozen_string_literal: true

FactoryBot.define do
  factory :panama_bank_account do
    association :user
    bank_number { "AAAAPAPAXXX" }
    account_number { "000123456789" }
    account_number_last_four { "6789" }
    account_holder_full_name { "Chuck Bartowski" }
  end
end
