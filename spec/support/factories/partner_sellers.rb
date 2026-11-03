# frozen_string_literal: true

FactoryBot.define do
  factory :partner_seller do
    association :oauth_application, is_partner: true, confidential: true, scopes: "partner_api"
    user
    sequence(:external_user_id) { |n| "partner-user-#{n}" }
  end
end
