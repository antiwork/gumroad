# frozen_string_literal: true

FactoryBot.define do
  factory :niger_bank_account do
    user
    account_number { "NE58NE0380100100130305000268" }
    account_number_last_four { "0268" }
    account_holder_full_name { "Niger Creator" }
  end
end
