# frozen_string_literal: true

# IRAS gives us two sets of credentials — one for Sandbox, and one for Production.
# We're using the Production set in production, and the Sandbox set everywhere else.
IRAS_API_ID = GlobalConfig.get("IRAS_API_ID")
IRAS_API_SECRET = GlobalConfig.get("IRAS_API_SECRET")

if Rails.env.production?
  IRAS_ENDPOINT = "https://apiservices.iras.gov.sg/iras/prod/GSTListing/SearchGSTRegistered"
else
  IRAS_ENDPOINT = "https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered"
end
