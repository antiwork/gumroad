# frozen_string_literal: true

FactoryBot.define do
  factory :mauritius_bank_account do
    user
    account_number { "MU17BOMM0101101030300200000MUR" }
    account_number_last_four { "0MUR" }
    bank_code { "AAAAMUMUXYZ" }
    account_holder_full_name { "John Doe" }
  end
end
