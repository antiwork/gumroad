# frozen_string_literal: true

FactoryBot.define do
  factory :uzbekistan_bank_account do
    user
    account_number { "99934500012345670024" }
    bank_code { "AAAAUZUZXXX" }
    branch_code { "00000" }
    account_number_last_four { "0024" }
    account_holder_full_name { "Chuck Bartowski" }
  end
end
