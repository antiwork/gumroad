# frozen_string_literal: true

FactoryBot.define do
  factory :mcp_event_subscription do
    user
    oauth_application
    event_name { McpEventSubscription::SALE_CREATED }
    arguments { {} }
    callback_url { "https://example.com/hooks/mcp" }
    secret { "whsec_#{Base64.strict_encode64(SecureRandom.bytes(32))}" }
    expires_at { 1.hour.from_now }
  end
end
