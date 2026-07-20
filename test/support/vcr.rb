# frozen_string_literal: true

require "vcr"

# VCR wiring for the Minitest suite.
#
# This mirrors spec/spec_helper.rb#configure_vcr, minus the RSpec-only
# `configure_rspec_metadata!` — the auto-naming that derives a cassette path from
# each example's describe/context/it chain. VCR itself is framework-agnostic, so
# the only thing the Minitest suite needs is the same configuration pointed at
# the same cassette directory. Existing recordings are reused byte-for-byte.
#
# Porting a cassette-backed spec: wrap the HTTP section of the test in
#   VCR.use_cassette("<the original RSpec description path>") { ... }
# using the name the RSpec metadata would have derived (e.g.
# "AssetPreview/Embeddable_link/succeeds_with_a_video_URL"). On CI the record
# mode is :none, so a wrong or missing cassette name errors loudly instead of
# silently reaching the network — the port is machine-checkable.
#
# Keep the ignore-hosts and sensitive-data lists in sync with spec_helper.
VCR.configure do |config|
  config.cassette_library_dir = Rails.root.join("spec", "support", "fixtures", "vcr_cassettes").to_s
  config.hook_into :webmock
  config.ignore_hosts "gumroad-specs.s3.amazonaws.com", "s3.amazonaws.com", "codeclimate.com", "mongo", "redis", "elasticsearch", "minio"
  config.ignore_hosts "api.knapsackpro.com", "googlechromelabs.github.io", "storage.googleapis.com"
  config.ignore_localhost = true
  config.debug_logger = $stdout if ENV["VCR_DEBUG"]
  # Same policy as the RSpec suite: replay-only on CI (a missing cassette fails
  # the build), record-once locally so a new cassette-backed test can capture.
  config.default_cassette_options[:record] = ENV["CI"].nil? ? :once : :none

  # Scrub the same secrets from any freshly-recorded cassette as spec_helper does.
  # (No-op on CI where nothing records; matters when recording locally.)
  %w[
    AWS_ACCOUNT_ID AWS_ACCESS_KEY_ID STRIPE_PLATFORM_ACCOUNT_ID STRIPE_API_KEY STRIPE_CONNECT_CLIENT_ID
    PAYPAL_USERNAME PAYPAL_PASSWORD PAYPAL_SIGNATURE STRONGBOX_GENERAL_PASSWORD DROPBOX_API_KEY
    SENDGRID_GUMROAD_TRANSACTIONS_API_KEY SENDGRID_GR_CREATORS_API_KEY SENDGRID_GR_CUSTOMERS_LEVEL_2_API_KEY
    SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_API_KEY BRAINTREE_API_PRIVATE_KEY BRAINTREE_MERCHANT_ID
    BRAINTREE_PUBLIC_KEY BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS PAYPAL_CLIENT_ID PAYPAL_CLIENT_SECRET
    PAYPAL_MERCHANT_EMAIL PAYPAL_PARTNER_CLIENT_ID PAYPAL_PARTNER_MERCHANT_ID PAYPAL_PARTNER_MERCHANT_EMAIL
    PAYPAL_BN_CODE VATSTACK_API_KEY IRAS_API_ID IRAS_API_SECRET TAXJAR_API_KEY TAX_ID_PRO_API_KEY
    CIRCLE_API_KEY OPEN_EXCHANGE_RATES_APP_ID UNSPLASH_CLIENT_ID DISCORD_BOT_TOKEN DISCORD_CLIENT_ID
    ZOOM_CLIENT_ID GCAL_CLIENT_ID OPENAI_ACCESS_TOKEN IOS_CONSUMER_APP_APPLE_LOGIN_IDENTIFIER
    IOS_CREATOR_APP_APPLE_LOGIN_TEAM_ID IOS_CREATOR_APP_APPLE_LOGIN_IDENTIFIER GOOGLE_CLIENT_ID
    RPUSH_CONSUMER_FCM_FIREBASE_PROJECT_ID CLOUDFRONT_KEYPAIR_ID
  ].each { |key| config.filter_sensitive_data("<#{key}>") { GlobalConfig.get(key) } }
end
