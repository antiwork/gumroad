# frozen_string_literal: true

Stripe.api_version = Rails.env.test? ? "2023-10-16" : "2023-10-16; risk_in_requirements_beta=v1; retrieve_tax_forms_beta=v1;"
# Ref: https://github.com/gumroad/web/issues/17770, https://stripe.com/docs/rate-limits#object-lock-timeouts
Stripe.max_network_retries = 3
if Rails.env.production?
  STRIPE_PUBLIC_KEY = GlobalConfig.get("STRIPE_PUBLIC_KEY_PROD", "pk_live_Db80xIzLPWhKo1byPrnERmym")
else
  STRIPE_PUBLIC_KEY = GlobalConfig.get("STRIPE_PUBLIC_KEY_TEST", Rails.env.test? ? "pk_test_dummy" : "pk_test_ehGPKw3JPRHYiqEEjgJ02ULC")
end
Stripe.api_key = GlobalConfig.get("STRIPE_API_KEY", Rails.env.test? ? "sk_test_dummy" : nil)
STRIPE_PLATFORM_ACCOUNT_ID = GlobalConfig.get("STRIPE_PLATFORM_ACCOUNT_ID", Rails.env.test? ? "acct_test_dummy" : nil)
STRIPE_CONNECT_CLIENT_ID = GlobalConfig.get("STRIPE_CONNECT_CLIENT_ID", Rails.env.test? ? "ca_test_dummy" : nil)
STRIPE_SECRET = GlobalConfig.get("STRIPE_API_KEY", Rails.env.test? ? "sk_test_dummy" : nil)
