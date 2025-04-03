# frozen_string_literal: true

FactoryBot.define do
  factory :sweden_bank_account do
    user
    account_number { "SE3550000000054910000003" }
    account_number_last_four { "0003" }
    account_holder_full_name { "Gumbot Gumstein I" }
  end
end
