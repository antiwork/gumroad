# frozen_string_literal: true

FactoryBot.define do
  factory :hungary_bank_account do
    user
    account_number { "HU42117730161111101800000000" }
    account_number_last_four { "2874" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
