# frozen_string_literal: true

# Vatstack gives us two API keys — one for Development, and one for Production.
# We're using the Production key in production, and the Development key everywhere else.
VATSTACK_API_KEY = GlobalConfig.get("VATSTACK_API_KEY")
