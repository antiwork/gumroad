# frozen_string_literal: true

FactoryBot.define do
  factory :ach_account do
    user
    account_number { "1112121234" }
    routing_number { "110000000" }
    account_number_last_four { "1234" }
    account_holder_full_name { "Gumbot Gumstein I" }
    account_type { "checking" }
  end

  factory :ach_account_2, parent: :ach_account do
    user
    account_number { "2222125678" }
    routing_number { "110000000" }
    account_number_last_four { "5678" }
    account_holder_full_name { "Gumbot Gumstein II" }
    account_type { "checking" }
  end

  factory :ach_account_stripe_succeed, parent: :ach_account do
    user
    account_number { "000123456789" }
    routing_number { "110000000" }
    account_number_last_four { "6789" }
    account_holder_full_name { "Stripe Test Account" }
    account_type { "checking" }
  end
end
