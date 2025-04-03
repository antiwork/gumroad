# frozen_string_literal: true

FactoryBot.define do
  factory :monaco_bank_account do
    user
    account_number { "MC5810096180790123456789085" }
    account_number_last_four { "9085" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
