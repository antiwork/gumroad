# frozen_string_literal: true

# IRAS gives us two sets of credentials — one for Sandbox, and one for Production.
# We're using the Production set in production, and the Sandbox set everywhere else.
IRAS_API_ID = GlobalConfig.get("IRAS_API_ID")
IRAS_API_SECRET = GlobalConfig.get("IRAS_API_SECRET")

IRAS_ENDPOINT = if Rails.env.production?
  "https://apiservices.iras.gov.sg/iras/prod/GSTListing/SearchGSTRegistered"
else
  "https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered"
end
