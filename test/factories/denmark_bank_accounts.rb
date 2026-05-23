# frozen_string_literal: true

FactoryBot.define do
  factory :denmark_bank_account do
    user
    account_number { "DK5000400440116243" }
    account_number_last_four { "2874" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
