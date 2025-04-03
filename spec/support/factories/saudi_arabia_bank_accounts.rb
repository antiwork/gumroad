# frozen_string_literal: true

FactoryBot.define do
  factory :saudi_arabia_bank_account do
    user
    account_number { "SA4420000001234567891234" }
    account_number_last_four { "1234" }
    bank_code { "RIBLSARIXXX" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
