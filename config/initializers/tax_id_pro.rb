# frozen_string_literal: true

# Tax ID Pro allows us to create multiple API keys.
# We're using two — one for Development, and one for Production.
# We're using the Production key in production, and the Development key everywhere else.
TAX_ID_PRO_API_KEY = GlobalConfig.get("TAX_ID_PRO_API_KEY")
