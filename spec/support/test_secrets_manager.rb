# frozen_string_literal: true

# TestSecretsManager provides mock credentials for running tests without real secrets
class TestSecretsManager
  # Mock credentials for different services
  MOCK_CREDENTIALS = {
    # AWS
    "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
    "AWS_SECRET_ACCESS_KEY" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "AWS_DEFAULT_REGION" => "us-east-1",
    "AWS_ACCOUNT_ID" => "123456789012",

    # Stripe
    "STRIPE_API_KEY" => "sk_test_mock_key_for_testing_only",
    "STRIPE_PUBLIC_KEY_TEST" => "pk_test_mock_key_for_testing_only",
    "STRIPE_PUBLIC_KEY_PROD" => "pk_test_mock_key_for_testing_only",
    "STRIPE_PLATFORM_ACCOUNT_ID" => "acct_1234567890",
    "STRIPE_CONNECT_CLIENT_ID" => "ca_1234567890",

    # PayPal
    "PAYPAL_USERNAME" => "test_api1.example.com",
    "PAYPAL_PASSWORD" => "test_password",
    "PAYPAL_SIGNATURE" => "test_signature_example",
    "PAYPAL_CLIENT_ID" => "test_client_id",
    "PAYPAL_CLIENT_SECRET" => "test_client_secret",
    "PAYPAL_MERCHANT_EMAIL" => "test@example.com",
    "PAYPAL_PARTNER_CLIENT_ID" => "test_partner_client_id",
    "PAYPAL_PARTNER_MERCHANT_ID" => "test_merchant_id",
    "PAYPAL_PARTNER_MERCHANT_EMAIL" => "partner@example.com",
    "PAYPAL_BN_CODE" => "test_bn_code",

    # Braintree
    "BRAINTREE_API_PRIVATE_KEY" => "test_private_key",
    "BRAINTREE_MERCHANT_ID" => "test_merchant_id",
    "BRAINTREE_PUBLIC_KEY" => "test_public_key",
    "BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS" => "test_merchant_account",

    # SendGrid
    "SENDGRID_GUMROAD_TRANSACTIONS_API_KEY" => "SG.test_key_transactions",
    "SENDGRID_GR_CREATORS_API_KEY" => "SG.test_key_creators",
    "SENDGRID_GR_CUSTOMERS_LEVEL_2_API_KEY" => "SG.test_key_customers",
    "SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_API_KEY" => "SG.test_key_followers",

    # Other APIs
    "DROPBOX_API_KEY" => "test_dropbox_key",
    "DROPBOX_PICKER_API_KEY" => "test_dropbox_picker_key",
    "EASYPOST_API_KEY" => "EZTK_test_key",
    "VATSTACK_API_KEY" => "test_vatstack_key",
    "TAXJAR_API_KEY" => "test_taxjar_key",
    "TAX_ID_PRO_API_KEY" => "test_tax_id_pro_key",
    "CIRCLE_API_KEY" => "test_circle_key",
    "OPEN_EXCHANGE_RATES_APP_ID" => "test_exchange_rates_id",
    "UNSPLASH_CLIENT_ID" => "test_unsplash_id",
    "DISCORD_BOT_TOKEN" => "test_discord_token",
    "DISCORD_CLIENT_ID" => "test_discord_client_id",
    "ZOOM_CLIENT_ID" => "test_zoom_client_id",
    "GCAL_CLIENT_ID" => "test_gcal_client_id",
    "OPENAI_ACCESS_TOKEN" => "test_openai_token",
    "GOOGLE_CLIENT_ID" => "test_google_client_id",
    "GOOGLE_CLIENT_SECRET" => "test_google_secret",
    "TWITTER_APP_ID" => "test_twitter_id",
    "TWITTER_APP_SECRET" => "test_twitter_secret",

    # IRAS
    "IRAS_API_ID" => "test_iras_id",
    "IRAS_API_SECRET" => "test_iras_secret",

    # Cloudfront
    "CLOUDFRONT_KEYPAIR_ID" => "APKAI23HVI5ZG5I7JSHQ",
    "CLOUDFRONT_PRIVATE_KEY" => "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA4f5wg5l2hKsTeNem/V41fGnJm6gOdrj8ym3rFkEjWT2bstSR\nTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLY\nTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLY\nTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLY\nTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLY\nTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLYTESTKEYONLY\n-----END RSA PRIVATE KEY-----",

    # Bugsnag
    "BUGSNAG_API_KEY" => "test_bugsnag_key",

    # Push notifications
    "RPUSH_CONSUMER_FCM_FIREBASE_PROJECT_ID" => "test-firebase-project",

    # Webhooks
    "SLACK_WEBHOOK_URL" => "https://hooks.slack.com/services/test/test/test",
    "IFFY_WEBHOOK_SECRET" => "test_iffy_secret",

    # Spec API
    "SPEC_API_USERNAME" => "test_spec_user",
    "SPEC_API_PASSWORD" => "test_spec_password",

    # Strongbox
    "STRONGBOX_GENERAL_PASSWORD" => "test_strongbox_password",

    # S3 Buckets
    "INVOICES_S3_BUCKET" => "test-gumroad-invoices",

    # Apple/iOS
    "IOS_CONSUMER_APP_APPLE_LOGIN_IDENTIFIER" => "com.test.gumroad.consumer",
    "IOS_CREATOR_APP_APPLE_LOGIN_TEAM_ID" => "TEST123456",
    "IOS_CREATOR_APP_APPLE_LOGIN_IDENTIFIER" => "com.test.gumroad.creator",

    # Environment identifiers
    "GUMROAD_ADMIN_ID" => "767082",
    "REVISION_DEFAULT" => "test-revision",
    "ENV_IDENTIFIER_DEV" => "TEST",
    "ENV_IDENTIFIER_PROD" => "TEST"
  }.freeze

  class << self
    # Get a mock credential value
    def get(key, default = nil)
      MOCK_CREDENTIALS.fetch(key, default)
    end

    # Enable test mode - patches GlobalConfig
    def enable!
      return if @enabled

      @original_global_config_get = GlobalConfig.method(:get)

      GlobalConfig.define_singleton_method(:get) do |key, default = :__no_default_provided__|
        if default == :__no_default_provided__
          TestSecretsManager.get(key) || TestSecretsManager.get(key, nil)
        else
          TestSecretsManager.get(key, default)
        end
      end

      @enabled = true
    end

    # Disable test mode - restore original GlobalConfig
    def disable!
      return unless @enabled

      GlobalConfig.define_singleton_method(:get, @original_global_config_get)
      @enabled = false
    end

    # Check if test mode is enabled
    def enabled?
      @enabled || false
    end
  end
end
