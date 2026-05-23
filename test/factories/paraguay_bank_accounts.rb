# frozen_string_literal: true

FactoryBot.define do
  factory :paraguay_bank_account do
    user
    account_number { "0567890123456789" }
    account_number_last_four { "6789" }
    bank_code { "0" }
    account_holder_full_name { "Paraguayan Creator" }
  end
end
