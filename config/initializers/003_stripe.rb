# frozen_string_literal: true

Stripe.api_version = "2023-10-16"
# Ref: https://github.com/gumroad/web/issues/17770, https://stripe.com/docs/rate-limits#object-lock-timeouts
Stripe.max_network_retries = 3
if Rails.env.production?
  STRIPE_PUBLIC_KEY = GlobalConfig.get("STRIPE_PUBLIC_KEY_PROD", "pk_live_Db80xIzLPWhKo1byPrnERmym")
else
  STRIPE_PUBLIC_KEY = GlobalConfig.get("STRIPE_PUBLIC_KEY_TEST", "pk_test_ehGPKw3JPRHYiqEEjgJ02ULC")
end
Stripe.api_key = GlobalConfig.get("STRIPE_API_KEY")
STRIPE_PLATFORM_ACCOUNT_ID = GlobalConfig.get("STRIPE_PLATFORM_ACCOUNT_ID")
STRIPE_CONNECT_CLIENT_ID = GlobalConfig.get("STRIPE_CONNECT_CLIENT_ID")
STRIPE_SECRET = GlobalConfig.get("STRIPE_API_KEY")
