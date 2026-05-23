# frozen_string_literal: true

FactoryBot.define do
  factory :trinidad_and_tobago_bank_account do
    user
    account_number { "00567890123456789" }
    bank_number { "999" }
    branch_code { "00001" }
    account_number_last_four { "6789" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
