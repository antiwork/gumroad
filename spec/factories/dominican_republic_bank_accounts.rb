# frozen_string_literal: true

FactoryBot.define do
  factory :dominican_republic_bank_account do
    user
    account_number { "000123456789" }
    bank_code { "999" }
    account_number_last_four { "6789" }
    account_holder_full_name { "Chuck Bartowski" }
  end
end
