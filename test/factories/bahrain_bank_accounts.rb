# frozen_string_literal: true

FactoryBot.define do
  factory :bahrain_bank_account do
    user
    account_number { "BH29BMAG1299123456BH00" }
    account_number_last_four { "BH00" }
    bank_code { "AAAABHBMXYZ" }
    account_holder_full_name { "Bahrainian Creator I" }
  end
end
