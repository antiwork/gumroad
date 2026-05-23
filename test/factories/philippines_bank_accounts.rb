# frozen_string_literal: true

FactoryBot.define do
  factory :philippines_bank_account do
    user
    account_number { "01567890123456789" }
    bank_number { "BCDEFGHI123" }
    account_number_last_four { "I123" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
