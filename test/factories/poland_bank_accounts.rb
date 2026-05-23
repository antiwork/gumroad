# frozen_string_literal: true

FactoryBot.define do
  factory :poland_bank_account do
    user
    account_number { "PL61109010140000071219812874" }
    account_number_last_four { "2874" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
