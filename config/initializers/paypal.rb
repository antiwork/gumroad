# frozen_string_literal: true

# Gumroad's PayPal merchant account details
PAYPAL_CLIENT_ID      = GlobalConfig.get("PAYPAL_CLIENT_ID")
PAYPAL_CLIENT_SECRET  = GlobalConfig.get("PAYPAL_CLIENT_SECRET")
PAYPAL_MERCHANT_EMAIL = GlobalConfig.get("PAYPAL_MERCHANT_EMAIL")

# Gumroad's PayPal partner account details
PAYPAL_BN_CODE               = GlobalConfig.get("PAYPAL_BN_CODE")
PAYPAL_PARTNER_ID            = GlobalConfig.get("PAYPAL_PARTNER_MERCHANT_ID")
PAYPAL_PARTNER_CLIENT_ID     = GlobalConfig.get("PAYPAL_PARTNER_CLIENT_ID")
PAYPAL_PARTNER_CLIENT_SECRET = GlobalConfig.get("PAYPAL_PARTNER_CLIENT_SECRET")
PAYPAL_PARTNER_EMAIL         = GlobalConfig.get("PAYPAL_PARTNER_MERCHANT_EMAIL")
PAYPAL_WEBHOOK_ID            = GlobalConfig.get("PAYPAL_WEBHOOK_ID")

# PayPal URLs
if Rails.env.production?
  PAYPAL_ENDPOINT      = "https://api-3t.paypal.com/nvp"
  PAYPAL_REST_ENDPOINT = "https://api.paypal.com"
  PAYPAL_URL           = "https://www.paypal.com"
  PAYPAL_IPN_VERIFICATION_URL = "https://ipnpb.paypal.com/cgi-bin/webscr"
else
  PAYPAL_ENDPOINT      = "https://api-3t.sandbox.paypal.com/nvp"
  PAYPAL_REST_ENDPOINT = "https://api.sandbox.paypal.com"
  PAYPAL_URL           = "https://www.sandbox.paypal.com"
  PAYPAL_IPN_VERIFICATION_URL = "https://ipnpb.sandbox.paypal.com/cgi-bin/webscr"
end

# PayPal credentials used in legacy NVP/SOAP API calls
PAYPAL_USER      = GlobalConfig.get("PAYPAL_USERNAME")
PAYPAL_PASS      = GlobalConfig.get("PAYPAL_PASSWORD")
PAYPAL_SIGNATURE = GlobalConfig.get("PAYPAL_SIGNATURE")

PayPal::SDK.configure(
  mode: (Rails.env.production? ? "live" : "sandbox"),
  client_id: PAYPAL_CLIENT_ID,
  client_secret: PAYPAL_CLIENT_SECRET,
  username: PAYPAL_USER,
  password: PAYPAL_PASS,
  signature: PAYPAL_SIGNATURE,
  ssl_options: { ca_file: nil }
)

PayPal::SDK.logger = Logger.new(STDERR)
