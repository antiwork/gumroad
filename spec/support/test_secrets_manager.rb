# frozen_string_literal: true

# TestSecretsManager provides automatic detection and mocking of missing secrets
# This allows tests to run without requiring real environment variables
module TestSecretsManager
  class << self
    attr_accessor :mocked_secrets, :missing_secrets

    def initialize!
      @mocked_secrets = []
      @missing_secrets = []
      @original_env = ENV.to_h.dup

      setup_test_defaults
      detect_and_mock_missing_secrets

      if @mocked_secrets.any?
        log_mocked_secrets
      end
    end

    def reset!
      @original_env&.each { |k, v| ENV[k] = v }
      @mocked_secrets = []
      @missing_secrets = []
    end

    private
      def setup_test_defaults
        # Core test defaults that should always be set in test environment
        test_defaults = {
          "RAILS_ENV" => "test",
          "RACK_ENV" => "test",
          "NODE_ENV" => "test",

          # Database defaults (assuming Docker services are running)
          "DATABASE_HOST" => ENV.fetch("DATABASE_HOST", "127.0.0.1"),
          "DATABASE_PORT" => ENV.fetch("DATABASE_PORT", "3306"),
          "DATABASE_NAME" => ENV.fetch("DATABASE_NAME", "gumroad_test"),
          "TEST_DATABASE_NAME" => ENV.fetch("TEST_DATABASE_NAME", "gumroad_test"),
          "DATABASE_USERNAME" => ENV.fetch("DATABASE_USERNAME", "root"),
          "DATABASE_PASSWORD" => ENV.fetch("DATABASE_PASSWORD", "password"),

          # MongoDB defaults
          "MONGO_DATABASE_URL" => ENV.fetch("MONGO_DATABASE_URL", "localhost:27017"),
          "MONGO_DATABASE_NAME" => ENV.fetch("MONGO_DATABASE_NAME", "gumroad_log_test"),

          # Redis defaults (different DBs for different purposes)
          "REDIS_HOST" => ENV.fetch("REDIS_HOST", "localhost:6379/10"),
          "SIDEKIQ_REDIS_HOST" => ENV.fetch("SIDEKIQ_REDIS_HOST", "localhost:6379/11"),
          "RPUSH_REDIS_HOST" => ENV.fetch("RPUSH_REDIS_HOST", "localhost:6379/12"),
          "RACK_ATTACK_REDIS_HOST" => ENV.fetch("RACK_ATTACK_REDIS_HOST", "localhost:6379/13"),

          # Elasticsearch
          "ELASTICSEARCH_HOST" => ENV.fetch("ELASTICSEARCH_HOST", "http://localhost:9200"),

          # Security keys (test-safe values)
          "DEVISE_SECRET_KEY" => ENV.fetch("DEVISE_SECRET_KEY", "test-devise-secret-" + "a" * 100),
          "STRONGBOX_GENERAL_PASSWORD" => ENV.fetch("STRONGBOX_GENERAL_PASSWORD", "test1234"),
        }

        test_defaults.each do |key, value|
          if ENV[key].nil? || ENV[key].empty?
            ENV[key] = value
            @mocked_secrets << key unless @original_env[key] == value
          end
        end
      end

      def detect_and_mock_missing_secrets
        # Payment processors
        mock_payment_secrets

        # AWS services
        mock_aws_secrets

        # Email services
        mock_email_secrets

        # Third-party APIs
        mock_third_party_secrets

        # Security and encryption
        mock_security_secrets
      end

      def mock_payment_secrets
        payment_secrets = {
          # Stripe
          "STRIPE_API_KEY" => "sk_test_#{generate_test_key(32)}",
          "STRIPE_PLATFORM_ACCOUNT_ID" => "acct_test#{generate_test_key(16)}",
          "STRIPE_CONNECT_CLIENT_ID" => "ca_test#{generate_test_key(24)}",
          "STRIPE_WEBHOOK_SECRET" => "whsec_test#{generate_test_key(32)}",

          # PayPal
          "PAYPAL_USERNAME" => "test_#{generate_test_key(8)}@paypal.com",
          "PAYPAL_PASSWORD" => "test_password_#{generate_test_key(16)}",
          "PAYPAL_SIGNATURE" => "test_signature_#{generate_test_key(24)}",
          "PAYPAL_CLIENT_ID" => "test_client_#{generate_test_key(32)}",
          "PAYPAL_CLIENT_SECRET" => "test_secret_#{generate_test_key(32)}",
          "PAYPAL_MERCHANT_EMAIL" => "merchant_#{generate_test_key(8)}@test.com",
          "PAYPAL_PARTNER_CLIENT_ID" => "partner_#{generate_test_key(32)}",
          "PAYPAL_PARTNER_MERCHANT_ID" => "merchant_#{generate_test_key(16)}",
          "PAYPAL_PARTNER_MERCHANT_EMAIL" => "partner_#{generate_test_key(8)}@test.com",
          "PAYPAL_BN_CODE" => "TestBNCode_#{generate_test_key(8)}",

          # Braintree
          "BRAINTREE_API_PRIVATE_KEY" => "test_private_#{generate_test_key(32)}",
          "BRAINTREE_MERCHANT_ID" => "test_merchant_#{generate_test_key(16)}",
          "BRAINTREE_PUBLIC_KEY" => "test_public_#{generate_test_key(32)}",
          "BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS" => "supplier_#{generate_test_key(16)}",

          # Circle
          "CIRCLE_API_KEY" => "test_circle_#{generate_test_key(32)}",
        }

        apply_mock_secrets(payment_secrets)
      end

      def mock_aws_secrets
        aws_secrets = {
          "AWS_ACCESS_KEY_ID" => "AKIA#{generate_test_key(16).upcase}",
          "AWS_SECRET_ACCESS_KEY" => generate_test_key(40),
          "AWS_DEFAULT_REGION" => "us-east-1",
          "AWS_ACCOUNT_ID" => "123456789012",
          "S3_DELETER_ACCESS_KEY_ID" => "AKIA#{generate_test_key(16).upcase}",
          "S3_DELETER_SECRET_ACCESS_KEY" => generate_test_key(40),
          "CLOUDFRONT_KEYPAIR_ID" => "APKA#{generate_test_key(16).upcase}",
          "CLOUDFRONT_PRIVATE_KEY" => generate_test_rsa_key,
          "INVOICES_S3_BUCKET" => "test-invoices-bucket",
        }

        apply_mock_secrets(aws_secrets)
      end

      def mock_email_secrets
        email_secrets = {
          "SENDGRID_GUMROAD_TRANSACTIONS_API_KEY" => "SG.test_transactions_#{generate_test_key(32)}",
          "SENDGRID_GR_CREATORS_API_KEY" => "SG.test_creators_#{generate_test_key(32)}",
          "SENDGRID_GR_CUSTOMERS_LEVEL_2_API_KEY" => "SG.test_customers_#{generate_test_key(32)}",
          "SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_API_KEY" => "SG.test_follower_#{generate_test_key(32)}",
          "RESEND_API_KEY" => "re_test_#{generate_test_key(32)}",
        }

        apply_mock_secrets(email_secrets)
      end

      def mock_third_party_secrets
        third_party_secrets = {
          # File storage
          "DROPBOX_API_KEY" => "test_dropbox_#{generate_test_key(32)}",

          # Shipping
          "EASYPOST_API_KEY" => "EZTKTEST_#{generate_test_key(32)}",

          # Tax services
          "VATSTACK_API_KEY" => "test_vatstack_#{generate_test_key(32)}",
          "TAXJAR_API_KEY" => "test_taxjar_#{generate_test_key(32)}",
          "TAX_ID_PRO_API_KEY" => "test_taxidpro_#{generate_test_key(32)}",
          "IRAS_API_ID" => "test_iras_#{generate_test_key(16)}",
          "IRAS_API_SECRET" => "test_iras_secret_#{generate_test_key(32)}",

          # Currency
          "OPEN_EXCHANGE_RATES_APP_ID" => "test_exchange_#{generate_test_key(32)}",

          # Media
          "UNSPLASH_CLIENT_ID" => "test_unsplash_#{generate_test_key(32)}",

          # Social/Communication
          "DISCORD_BOT_TOKEN" => "test_discord_bot_#{generate_test_key(32)}",
          "DISCORD_CLIENT_ID" => "test_discord_#{generate_test_key(18)}",
          "ZOOM_CLIENT_ID" => "test_zoom_#{generate_test_key(32)}",
          "ZOOM_CLIENT_SECRET" => "test_zoom_secret_#{generate_test_key(32)}",
          "GCAL_CLIENT_ID" => "test_gcal_#{generate_test_key(32)}.apps.googleusercontent.com",
          "GOOGLE_CLIENT_ID" => "test_google_#{generate_test_key(32)}.apps.googleusercontent.com",

          # AI
          "OPENAI_ACCESS_TOKEN" => "sk-test#{generate_test_key(48)}",

          # Mobile apps
          "IOS_CONSUMER_APP_APPLE_LOGIN_IDENTIFIER" => "com.test.consumer",
          "IOS_CREATOR_APP_APPLE_LOGIN_TEAM_ID" => "TEST#{generate_test_key(6).upcase}",
          "IOS_CREATOR_APP_APPLE_LOGIN_IDENTIFIER" => "com.test.creator",
          "RPUSH_CONSUMER_FCM_FIREBASE_PROJECT_ID" => "test-firebase-project",

          # Webhooks
          "SLACK_WEBHOOK_URL" => "https://hooks.slack.com/services/TEST/TEST/#{generate_test_key(24)}",
          "IFFY_WEBHOOK_SECRET" => "test_iffy_#{generate_test_key(32)}",
        }

        apply_mock_secrets(third_party_secrets)
      end

      def mock_security_secrets
        security_secrets = {
          "RAILS_MASTER_KEY" => generate_test_key(32),
          "SECURE_ENCRYPT_KEY" => generate_test_key(32),
          "OBFUSCATE_IDS_CIPHER_KEY" => generate_test_key(32),
          "OBFUSCATE_IDS_NUMERIC_CIPHER_KEY" => generate_numeric_key(9),
          "MAILER_HEADERS_ENCRYPTION_KEY_V1" => generate_test_key(32),
        }

        # Special handling for STRONGBOX_GENERAL (RSA key pair)
        if ENV["STRONGBOX_GENERAL"].nil? || ENV["STRONGBOX_GENERAL"].empty?
          ENV["STRONGBOX_GENERAL"] = generate_test_strongbox_key
          @mocked_secrets << "STRONGBOX_GENERAL"
        end

        apply_mock_secrets(security_secrets)
      end

      def apply_mock_secrets(secrets)
        secrets.each do |key, value|
          if ENV[key].nil? || ENV[key].empty?
            ENV[key] = value
            @mocked_secrets << key
          end
        end
      end

      def generate_test_key(length)
        SecureRandom.alphanumeric(length)
      end

      def generate_numeric_key(length)
        Array.new(length) { rand(0..9) }.join
      end

      def generate_test_rsa_key
        "-----BEGIN PRIVATE KEY-----\nMIIEvQtest#{generate_test_key(700)}\n-----END PRIVATE KEY-----"
      end

      def generate_test_strongbox_key
        # This is a test RSA key pair that matches the format expected by Strongbox
        <<~KEY
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: DES-EDE3-CBC,14957F59FBB1404B

        dIBUwXHDIeooeT1u+iBLu9sxbeF0Kh/y2e1fUXhUaRXAVrnEaINrlcAC0OpDxlr8
        ZUSZXkukrarCP7qx12B8b6PBzImgOOyy7x5jOVf+iPn0FiUR9HaSg848p2o6tQvt
        pdm4FS8EOivBNQBNAK5H1XPuCwBVWEqTrkzQbaR276zX9U3hErtG50Jg1pjQXoqV
        /Agh6LrcSVYmy0otEbviMoEAjW+aA4aWN9KanVG7yoJI0RwQFrXM/v7fDg2lBS4p
        Fm4hlXYRoOuLBJ6zm/O0BIyq8TRMgwnAcI1yLxnLkRBPfjROPBboP3UxcpGRejB0
        E5I5odEjvyzQfNGpfDJcESHSUoep/5H2nJ8fMQKHNL7EWnwP/29OmEYQ8hqY7zCL
        kKsWQKBvHfqsYXE9SN8U1i6YU8YOUV1qO2fIXtXrW3T9fJCEL7DEg+vbbzbI/f5R
        H+0m1xDI6qBa+BCpotuizl8hgH4/r3WwqMEP0G9W6w5281JBIcRieg3cOCI7AotQ
        ZSHfvWb2ptRBoTi11M3QmlZeq6Zf5eRpVyOXDpBVdFZVaJw63y/yFNb7qJM023I/
        aB7KeOSbeFsDz4DF47ViB43MiisJ0CNWkmwow/jMy4EwEjT0EsIf/sXKkPctBjuY
        kdR1JR+Vxe+pipJwzi9aM3zamTyvutBw2rVqzPHM0kb1JIi2wsaiuySReXchUHgM
        9j9DvD2NxegbAjIDdZ+tLt94GVreJSqdPlNItmZh5i6XKsbHDKiujz904qGP36Kh
        feHLEZBG7ua7SlSkshY9Re7GUmkRNPujAtSbxPwfFpPu30IEGPes1Jyn4Ewlj7g+
        0YzB6f2FXyF1PmUwVfmqnUN2T67jhsr3EL608mV8QBy/HfudJST6lsrgu7VKrtiM
        7AyWW+ryO6EIJH/R117d/2a0QC/kfA7BQ/UQiFa7Bsku3LpQBRRVHTvhUIKKC8ry
        XpH1iecmx1JnIdZXv8u47eieAA+8Kprt5tbyxz09KEuu4jpnFl5Drv6fn7ZPAT8B
        rXFzObvot8OdcjIXnzbcJKp+liHcyOfOTYnit9HnG6xB4X4hEAFWIcu0zO6CfcQa
        uP0yUPnNT71//7nR9AsJ69XeOVjp4gQIfpbqAV31x7Iq3K3dMFPhDCs2v9MpKUYo
        34iZRw3BW9UksxLAWKHUEIS4afAKqz/wCQhXZ4OVJwNF4tZRuVRguLtjuDUiyque
        0ZKmSWi06faMRsYlwnbtZjD2wK4TKxPuystAUQWrImDExvP+pDPU3Y++vAS2ok9Q
        BEYqH9tPdZ7fmD6lFt5xAt88ukT6nWHaNmHjilN1GT/P++z7Z4RIvIk/VQZ6S2qm
        0VytO16EwUEyr3VAEv6k0tZcfOcBiFC7/LuoWlGAFmjBiO7BqQ2VwyhDsZKN+nvq
        x2T5HzjGR+/kXv6vfPWJVUYsDApU7JhsoGPoz4HEPcpEje0PuzkFCDcV798NArn3
        OnH3bgymVFpoUEk5oplTcVNMFrMCn7NheUECzryn4L3Bj20EZYUMdE/+g7HmoXv0
        RpL7N9gHTemG08ufA+0jBqYZoMtcStC5bLP5TqcLaNd6uWCixj3OoYWQiA+fwvE6
        -----END RSA PRIVATE KEY-----
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvFtatcBU3q5VKkNpykda
        d48gVT6tQjqNeh07ZYe5Zc1jTjzZ98nSo/KrRfmH0zknR/muc+seBrx3JlwIwrsK
        SisFxaiKkHs/2MpO3FkPS2sfOkwup7tDFOPqQwm12t3KNg7CxP4r1W7YftMYRDzg
        yDntmSprURO9NEMmgQx3ChNlaO1oDbzPDOTFzQR1St7IKhC3nZ4oF5ePwttJHdI9
        sSnjzyuftaSTsk/zm1a4zp2CfSd0L6oWmWX8/3l3fcjn/KcSjZd+hr6kdODO09Ij
        a/qx5zUtPWE1W7QfmZFYzNelMv0xuuyGChKpEUJsLZIaqGihbjWAPKwuJEoDQr7w
        pwIDAQAB
        -----END PUBLIC KEY-----
        KEY
      end

      def log_mocked_secrets
        puts "\n" + "=" * 80
        puts "TEST SECRETS MANAGER - Mocking #{@mocked_secrets.count} secrets"
        puts "=" * 80

        if ENV["DEBUG_TEST_SECRETS"] == "true"
          puts "\nMocked secrets:"
          @mocked_secrets.sort.each do |secret|
            masked_value = ENV[secret].to_s[0..10] + "..."
            puts "  • #{secret} = #{masked_value}"
          end
        else
          puts "\nMocked secret categories:"
          categories = {
            "Payment" => @mocked_secrets.select { |s| s =~ /STRIPE|PAYPAL|BRAINTREE|CIRCLE/ },
            "AWS" => @mocked_secrets.select { |s| s =~ /AWS|S3|CLOUDFRONT/ },
            "Email" => @mocked_secrets.select { |s| s =~ /SENDGRID|RESEND/ },
            "Tax" => @mocked_secrets.select { |s| s =~ /VAT|TAX|IRAS/ },
            "Third-party" => @mocked_secrets.select { |s| s =~ /DISCORD|ZOOM|GCAL|GOOGLE|OPENAI|UNSPLASH|DROPBOX|EASYPOST|EXCHANGE|SLACK|IFFY/ },
            "Security" => @mocked_secrets.select { |s| s =~ /KEY|SECRET|PASSWORD|STRONGBOX|CIPHER|ENCRYPT/ },
          }

          categories.each do |category, secrets|
            if secrets.any?
              puts "  #{category}: #{secrets.count} secrets"
            end
          end
        end

        puts "\n💡 To see detailed secret names, set DEBUG_TEST_SECRETS=true"
        puts "💡 To disable test secrets, set DISABLE_TEST_SECRETS=true"
        puts "=" * 80 + "\n"
      end
  end
end

# Initialize automatically unless disabled
unless ENV["DISABLE_TEST_SECRETS"] == "true"
  TestSecretsManager.initialize!
end
