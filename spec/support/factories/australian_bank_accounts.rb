# frozen_string_literal: true

FactoryBot.define do
  factory :australian_bank_account do
    user
    account_number { "1234567" }
    bsb_number { "062111" }
    account_number_last_four { "4567" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
