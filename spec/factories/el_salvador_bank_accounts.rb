# frozen_string_literal: true

FactoryBot.define do
  factory :el_salvador_bank_account do
    association :user
    bank_number { "AAAASVS1XXX" }
    account_number { "12345678901234" }
    account_number_last_four { "1234" }
    account_holder_full_name { "Chuck Bartowski" }
  end
end
