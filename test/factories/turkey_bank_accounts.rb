# frozen_string_literal: true

FactoryBot.define do
  factory :turkey_bank_account do
    user
    account_number { "TR320010009999901234567890" }
    account_number_last_four { "7890" }
    bank_code { "ADABTRIS" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
