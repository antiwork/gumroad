# frozen_string_literal: true

FactoryBot.define do
  factory :liechtenstein_bank_account do
    user
    account_number { "LI0508800636123378777" }
    account_number_last_four { "8777" }
    account_holder_full_name { "Liechtenstein Creator" }
  end
end
