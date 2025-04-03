# frozen_string_literal: true

FactoryBot.define do
  factory :peru_bank_account do
    user
    account_number { "99934500012345670024" }
    account_number_last_four { "0024" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
