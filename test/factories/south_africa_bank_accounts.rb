# frozen_string_literal: true

FactoryBot.define do
  factory :south_africa_bank_account do
    user
    account_number { "000001234" }
    account_number_last_four { "0054" }
    bank_code { "FIRNZAJJ" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
