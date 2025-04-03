# frozen_string_literal: true

FactoryBot.define do
  factory :gibraltar_bank_account do
    user
    account_number { "GI75NWBK000000007099453" }
    account_number_last_four { "9453" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
