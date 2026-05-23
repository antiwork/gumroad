# frozen_string_literal: true

FactoryBot.define do
  factory :senegal_bank_account do
    user
    account_number { "SN08SN0100152000048500003035" }
    account_number_last_four { "3035" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
