# frozen_string_literal: true

FactoryBot.define do
  factory :egypt_bank_account do
    user
    account_number { "EG800002000156789012345180002" }
    account_number_last_four { "1111" }
    bank_code { "NBEGEGCX331" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
