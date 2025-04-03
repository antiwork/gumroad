# frozen_string_literal: true

FactoryBot.define do
  factory :swiss_bank_account do
    user
    account_number { "CH9300762011623852957" }
    account_number_last_four { "3000" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
