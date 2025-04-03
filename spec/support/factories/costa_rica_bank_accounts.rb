# frozen_string_literal: true

FactoryBot.define do
  factory :costa_rica_bank_account do
    user
    account_number { "CR04010212367856709123" }
    account_number_last_four { "9123" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
