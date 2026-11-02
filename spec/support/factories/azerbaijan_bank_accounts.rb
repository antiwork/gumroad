# frozen_string_literal: true

FactoryBot.define do
  factory :azerbaijan_bank_account do
    user
    account_number { "AZ77ADJE12345678901234567890" }
    account_number_last_four { "7890" }
    bank_code { "200004" }
    branch_code { "200004" }
    account_holder_full_name { "Azerbaijani Creator I" }
  end
end
