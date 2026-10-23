# frozen_string_literal: true

FactoryBot.define do
  factory :feature_announcement_delivery do
    campaign { "piracy_reports" }
    user
    email { user.email }
    state { "delivered" }
  end
end
