# frozen_string_literal: true

FactoryBot.define do
  factory :iceland_bank_account do
    user
    account_number { "IS140159260076545510730339" }
    account_number_last_four { "0339" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
