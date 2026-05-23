# frozen_string_literal: true

FactoryBot.define do
  factory :european_bank_account do
    user
    account_number { "DE89370400440532013000" }
    account_number_last_four { "3000" }
    account_holder_full_name { "Stripe DE Account" }
    account_type { "checking" }
  end

  factory :nl_bank_account, parent: :european_bank_account do
    user
    account_number { "NL89370400440532013000" }
    account_number_last_four { "3000" }
    account_holder_full_name { "Stripe NL Account" }
    account_type { "checking" }
  end

  factory :fr_bank_account, parent: :european_bank_account do
    user
    account_number { "FR89370400440532013000" }
    account_number_last_four { "3000" }
    account_holder_full_name { "Stripe FR Account" }
    account_type { "checking" }
  end
end
