# frozen_string_literal: true

FactoryBot.define do
  factory :israel_bank_account do
    user
    account_number { "IL620108000000099999999" }
    account_number_last_four { "9999" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
