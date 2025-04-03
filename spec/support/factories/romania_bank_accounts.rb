# frozen_string_literal: true

FactoryBot.define do
  factory :romania_bank_account do
    user
    account_number { "RO49AAAA1B31007593840000" }
    account_number_last_four { "0000" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
