# frozen_string_literal: true

# TaxJar gives us two API keys: one for Sandbox, and one for Live.
# We're using the Live key in production, and the Sandbox key everywhere else.
TAXJAR_API_KEY = GlobalConfig.get("TAXJAR_API_KEY")

TAXJAR_ENDPOINT = if Rails.env.production?
  "https://api.taxjar.com"
else
  "https://api.sandbox.taxjar.com"
end
