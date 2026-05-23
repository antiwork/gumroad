# frozen_string_literal: true

FactoryBot.define do
  factory :morocco_bank_account do
    user
    account_number { "MA64011519000001205000534921" }
    account_number_last_four { "4921" }
    bank_code { "AAAAMAMAXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
