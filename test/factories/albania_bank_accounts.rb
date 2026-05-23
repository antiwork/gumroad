# frozen_string_literal: true

FactoryBot.define do
  factory :albania_bank_account do
    user
    account_number { "AL35202111090000000001234567" }
    account_number_last_four { "4567" }
    bank_code { "AAAAALTXXXX" }
    account_holder_full_name { "Albanian Creator I" }
  end
end
