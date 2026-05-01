# frozen_string_literal: true

FactoryBot.define do
  factory :el_salvador_bank_account do
    association :user
    bank_number { "AAAASVS1XXX" }
    account_number { "SV44BCIE12345678901234567890" }
    account_number_last_four { "7890" }
    account_holder_full_name { "Chuck Bartowski" }
  end
end
