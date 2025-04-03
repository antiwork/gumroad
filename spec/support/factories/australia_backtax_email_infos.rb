# frozen_string_literal: true

FactoryBot.define do
  factory :australia_backtax_email_info do
    user
    email_name { "email_for_taxes_owed" }
    sent_at { Time.current }
  end
end
