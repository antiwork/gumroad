# frozen_string_literal: true

FactoryBot.define do
  factory :subscription_event do
    subscription
    event_type { :deactivated }
    occurred_at { Time.current }
  end
end
