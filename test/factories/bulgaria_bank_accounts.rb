# frozen_string_literal: true

FactoryBot.define do
  factory :bulgaria_bank_account do
    user
    account_number { "BG80BNBG96611020345678" }
    account_number_last_four { "2874" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
