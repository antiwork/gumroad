# frozen_string_literal: true

FactoryBot.define do
  factory :cote_d_ivoire_bank_account do
    user
    account_number { "CI93CI0080111301134291200589" }
    account_number_last_four { "0589" }
    account_holder_full_name { "Cote d'Ivoire Creator" }
  end
end
