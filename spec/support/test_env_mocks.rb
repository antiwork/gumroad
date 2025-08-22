# frozen_string_literal: true

# TestEnvMocks provides a centralized way to mock environment variables in tests
# This prevents tests from depending on actual environment variables and makes them more reliable
module TestEnvMocks
  # Store original ENV values to restore later if needed
  @original_env = {}

  class << self
    # Set up environment variables directly (not using RSpec mocks)
    def setup_env_variables
      # Test configuration variables
      mock_env_var("CI", nil)
      mock_env_var("IN_DOCKER", "false")
      mock_env_var("VCR_DEBUG", nil)
      mock_env_var("LOG_ES", "false")
      mock_env_var("ENABLE_RAISE_JS_ERROR", "0")
      mock_env_var("RAILS_ENV", "test")

      # Helper widget variables
      mock_env_var("HELPER_WIDGET_HOST", nil)
      mock_env_var("HELPER_WIDGET_SECRET", "test_secret")

      # SSL certificates
      mock_env_var("LETS_ENCRYPT_ACCOUNT_PRIVATE_KEY", nil)

      # Sidekiq variables
      mock_env_var("SIDEKIQ_GRACEFUL_SHUTDOWN_TIMEOUT", "3")
      mock_env_var("SIDEKIQ_LIFECYCLE_HOOK_NAME", "sample_hook_name")
      mock_env_var("SIDEKIQ_ASG_NAME", "sample_asg_name")

      # Payment processing variables
      mock_env_var("STRIPE_API_KEY", "sk_test_mock_stripe_key")
      mock_env_var("STRIPE_PLATFORM_ACCOUNT_ID", "acct_mock_platform")
      mock_env_var("STRIPE_CONNECT_CLIENT_ID", "ca_mock_connect_client")
      mock_env_var("PAYPAL_USERNAME", "mock_paypal_username")
      mock_env_var("PAYPAL_PASSWORD", "mock_paypal_password")
      mock_env_var("PAYPAL_SIGNATURE", "mock_paypal_signature")
      mock_env_var("BRAINTREE_API_PRIVATE_KEY", "mock_braintree_private_key")
      mock_env_var("BRAINTREE_MERCHANT_ID", "mock_braintree_merchant")
      mock_env_var("BRAINTREE_PUBLIC_KEY", "mock_braintree_public_key")

      # Email service variables
      mock_env_var("SENDGRID_GUMROAD_TRANSACTIONS_API_KEY", "SG.mock_transactions_key")
      mock_env_var("SENDGRID_GR_CREATORS_API_KEY", "SG.mock_creators_key")
      mock_env_var("SENDGRID_GR_CUSTOMERS_API_KEY", "SG.mock_customers_key")
      mock_env_var("SENDGRID_GR_CUSTOMERS_LEVEL_2_API_KEY", "SG.mock_customers_level2_key")
      mock_env_var("SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_API_KEY", "SG.mock_follower_key")

      # AWS variables
      mock_env_var("AWS_ACCOUNT_ID", "123456789012")
      mock_env_var("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
      mock_env_var("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

      # Security variables
      mock_env_var("STRONGBOX_GENERAL_PASSWORD", "mock_strongbox_password")

      # Third-party service variables
      mock_env_var("CIRCLE_API_KEY", "mock_circle_api_key")
      mock_env_var("EASYPOST_API_KEY", "mock_easypost_key")
      mock_env_var("DROPBOX_API_KEY", "mock_dropbox_key")
      mock_env_var("VATSTACK_API_KEY", "mock_vatstack_key")
      mock_env_var("TAXJAR_API_KEY", "mock_taxjar_key")
      mock_env_var("OPEN_EXCHANGE_RATES_APP_ID", "mock_exchange_rates_id")
      mock_env_var("GOOGLE_CLIENT_ID", "mock_google_client_id")
      mock_env_var("GOOGLE_CLIENT_SECRET", "mock_google_client_secret")
      mock_env_var("ZOOM_CLIENT_ID", "mock_zoom_client_id")
      mock_env_var("ZOOM_CLIENT_SECRET", "mock_zoom_client_secret")
      mock_env_var("IFFY_API_KEY", "mock_iffy_api_key")
      mock_env_var("IFFY_WEBHOOK_SECRET", "mock_iffy_webhook_secret")

      # iOS app variables
      mock_env_var("IOS_CONSUMER_APP_APPLE_LOGIN_IDENTIFIER", "mock_ios_consumer_identifier")
      mock_env_var("IOS_CREATOR_APP_APPLE_LOGIN_TEAM_ID", "mock_ios_creator_team_id")
      mock_env_var("IOS_CREATOR_APP_APPLE_LOGIN_IDENTIFIER", "mock_ios_creator_identifier")

      # reCAPTCHA variables
      mock_env_var("RECAPTCHA_MONEY_SITE_KEY", "mock_recaptcha_money_key")
      mock_env_var("RECAPTCHA_LOGIN_SITE_KEY", "mock_recaptcha_login_key")
      mock_env_var("RECAPTCHA_SIGNUP_SITE_KEY", "mock_recaptcha_signup_key")

      # Other service variables
      mock_env_var("CLOUDFRONT_KEYPAIR_ID", "mock_cloudfront_keypair")
      mock_env_var("SLACK_WEBHOOK_URL", "https://hooks.slack.com/services/mock/slack/webhook")

      # PayPal variables
      mock_env_var("PAYPAL_CLIENT_ID", "mock_paypal_client_id")
      mock_env_var("PAYPAL_CLIENT_SECRET", "mock_paypal_client_secret")
      mock_env_var("PAYPAL_MERCHANT_EMAIL", "mock_paypal_merchant@example.com")
      mock_env_var("PAYPAL_PARTNER_CLIENT_ID", "mock_paypal_partner_client_id")
      mock_env_var("PAYPAL_PARTNER_MERCHANT_ID", "mock_paypal_partner_merchant_id")
      mock_env_var("PAYPAL_PARTNER_MERCHANT_EMAIL", "mock_paypal_partner_merchant@example.com")
      mock_env_var("PAYPAL_BN_CODE", "mock_paypal_bn_code")

      # Tax and compliance variables
      mock_env_var("IRAS_API_ID", "mock_iras_api_id")
      mock_env_var("IRAS_API_SECRET", "mock_iras_api_secret")
      mock_env_var("TAX_ID_PRO_API_KEY", "mock_tax_id_pro_key")

      # Additional service variables
      mock_env_var("UNSPLASH_CLIENT_ID", "mock_unsplash_client_id")
      mock_env_var("DISCORD_BOT_TOKEN", "mock_discord_bot_token")
      mock_env_var("DISCORD_CLIENT_ID", "mock_discord_client_id")
      mock_env_var("GCAL_CLIENT_ID", "mock_gcal_client_id")
      mock_env_var("OPENAI_ACCESS_TOKEN", "mock_openai_token")
      mock_env_var("RPUSH_CONSUMER_FCM_FIREBASE_PROJECT_ID", "mock_firebase_project_id")
      mock_env_var("RPUSH_CONSUMER_FCM_JSON_KEY", "mock_fcm_json_key")

      # Environment variables are now set directly
      # RSpec mocks will be set up in before(:each) hooks
    end

    # Set an environment variable directly
    def mock_env_var(name, value)
      # Store original value if not already stored
      @original_env[name] ||= ENV[name] if ENV.key?(name)

      if value.nil?
        ENV.delete(name)
      else
        ENV[name] = value
      end
    end

    # Mock multiple environment variables at once
    def mock_env_vars(vars_hash)
      vars_hash.each do |name, value|
        mock_env_var(name, value)
      end
    end

    # Temporarily set an environment variable for a specific test
    def with_mocked_env_var(name, value)
      original_value = ENV[name]
      mock_env_var(name, value)
      yield
    ensure
      if original_value
        ENV[name] = original_value
      else
        ENV.delete(name)
      end
    end

    # Restore original environment variables
    def restore_original_env
      @original_env.each do |name, value|
        if value.nil?
          ENV.delete(name)
        else
          ENV[name] = value
        end
      end
      @original_env.clear
    end
  end
end

# Set up environment variables immediately when this file is loaded
# This ensures they're available before Rails initializers run
TestEnvMocks.setup_env_variables

# Include TestEnvMocks in RSpec configuration
RSpec.configure do |config|
  config.before(:each) do
    # Mock GlobalConfig to use our environment variables
    allow(GlobalConfig).to receive(:get).and_call_original
  end

  config.after(:suite) do
    TestEnvMocks.restore_original_env
  end
end
