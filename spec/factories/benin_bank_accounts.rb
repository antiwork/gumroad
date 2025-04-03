# frozen_string_literal: true

FactoryBot.define do
  factory :benin_bank_account do
    user
    account_number { "BJ66BJ0610100100144390000769" }
    account_number_last_four { "0769" }
    account_holder_full_name { "Benin Creator" }
  end
end
