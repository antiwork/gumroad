# frozen_string_literal: true

FactoryBot.define do
  factory :jordan_bank_account do
    user
    account_number { "JO32ABCJ0010123456789012345678" }
    account_number_last_four { "5678" }
    bank_code { "AAAAJOJOXXX" }
    account_holder_full_name { "Jordanian Creator I" }
  end
end
