# frozen_string_literal: true

FactoryBot.define do
  factory :uae_bank_account do
    user
    account_number { "AE070331234567890123456" }
    account_number_last_four { "3456" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
