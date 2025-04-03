# frozen_string_literal: true

GUMROAD_VAT_REGISTRATION_NUMBER = GlobalConfig.get("VAT_REGISTRATION_NUMBER", "EU826410924")
GUMROAD_AUSTRALIAN_BUSINESS_NUMBER = GlobalConfig.get("AUSTRALIAN_BUSINESS_NUMBER", "11 374 928 117")
GUMROAD_CANADA_GST_REGISTRATION_NUMBER = GlobalConfig.get("CANADA_GST_REGISTRATION_NUMBER", "701850612 RT9999")
GUMROAD_QST_REGISTRATION_NUMBER = GlobalConfig.get("QST_REGISTRATION_NUMBER", "NR00086053")
GUMROAD_NORWAY_VAT_REGISTRATION = GlobalConfig.get("NORWAY_VAT_REGISTRATION", "VOEC NO. 2082039")

# TODO: This is a placeholder for other tax registration numbers.
# As we activate "collect_tax_*" features, we'll need to add the appropriate
# tax registration number here for each country. (curtiseinsmann)
GUMROAD_OTHER_TAX_REGISTRATION = GlobalConfig.get("OTHER_TAX_REGISTRATION", "OTHER")

REPORTING_S3_BUCKET = if Rails.env.production?
  GlobalConfig.get("REPORTING_S3_BUCKET_PROD", "gumroad-reporting")
else
  GlobalConfig.get("REPORTING_S3_BUCKET_DEV", "gumroad-reporting-dev")
end

GUMROAD_MERCHANT_DESCRIPTOR_PHONE_NUMBER = GlobalConfig.get("MERCHANT_DESCRIPTOR_PHONE", "(650)742-3913") # Must be 10-14
GUMROAD_MERCHANT_DESCRIPTOR_URL = GlobalConfig.get("MERCHANT_DESCRIPTOR_URL", "gumroad.com/c") # Must be 0-13

GUMROAD_LOGO_URL = GlobalConfig.get("LOGO_URL", "https://gumroad.com/button/button_logo.png")

module GumroadAddress
  STREET = GlobalConfig.get("ADDRESS_STREET", "548 Market St")
  CITY = GlobalConfig.get("ADDRESS_CITY", "San Francisco")
  STATE = GlobalConfig.get("ADDRESS_STATE", "CA")
  ZIP = GlobalConfig.get("ADDRESS_ZIP", "94104")
  ZIP_PLUS_FOUR = "#{ZIP}-#{GlobalConfig.get("ADDRESS_ZIP_PLUS_FOUR", "5401")}"
  COUNTRY = ISO3166::Country[GlobalConfig.get("ADDRESS_COUNTRY", "US")]

  def self.full
    "#{STREET}, #{CITY}, #{STATE} #{ZIP_PLUS_FOUR}, #{COUNTRY.alpha3}"
  end
end
