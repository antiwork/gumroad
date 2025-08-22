# frozen_string_literal: true

require_relative "service_mocks/stripe_mock"
require_relative "service_mocks/paypal_mock"
require_relative "service_mocks/aws_mock"
require_relative "service_mocks/sendgrid_mock"
require_relative "service_mocks/taxjar_mock"

# ExternalServiceMocks provides comprehensive mocking for all external services
# This ensures tests never make real HTTP calls to external APIs
module ExternalServiceMocks
  class << self
    def setup!
      return if ENV["DISABLE_SERVICE_MOCKS"] == "true"
      return unless defined?(WebMock)

      # Allow local connections only
      WebMock.disable_net_connect!(
        allow_localhost: true,
        allow: [
          "gumroad-specs.s3.amazonaws.com",
          "s3.amazonaws.com",
          "codeclimate.com",
          "api.knapsackpro.com",
          "googlechromelabs.github.io",
          "storage.googleapis.com"
        ]
      )

      # Setup service-specific mocks
      setup_payment_mocks
      setup_aws_mocks
      setup_email_mocks
      setup_tax_mocks
      setup_third_party_mocks

      log_mock_status if ENV["DEBUG_SERVICE_MOCKS"] == "true"
    end

    private
      def setup_payment_mocks
        StripeMock.setup!
        PaypalMock.setup!
        setup_braintree_mocks
        setup_circle_mocks
      end

      def setup_aws_mocks
        AwsMock.setup!
      end

      def setup_email_mocks
        SendgridMock.setup!
        setup_resend_mocks
      end

      def setup_tax_mocks
        TaxjarMock.setup!
        setup_vatstack_mocks
        setup_tax_id_pro_mocks
      end

    def setup_third_party_mocks
      setup_discord_mocks
      setup_zoom_mocks
      setup_google_mocks
      setup_openai_mocks
      setup_unsplash_mocks
      setup_dropbox_mocks
      setup_easypost_mocks
      setup_exchange_rates_mocks
    end

      def setup_braintree_mocks
        # Braintree gateway mocks
        WebMock.stub_request(:any, /api\.braintreegateway\.com/).to_return(
          status: 200,
          body: { success: true, transaction: { id: "test_txn_#{SecureRandom.hex(8)}" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_circle_mocks
        # Circle API mocks
        WebMock.stub_request(:any, /api\.circle\.com/).to_return(
          status: 200,
          body: { data: { id: "test_circle_#{SecureRandom.hex(8)}", status: "complete" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_resend_mocks
        # Resend email API mocks
        WebMock.stub_request(:post, /api\.resend\.com\/emails/).to_return(
          status: 200,
          body: { id: "test_email_#{SecureRandom.hex(8)}", object: "email" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_vatstack_mocks
        # VATStack validation mocks
        WebMock.stub_request(:get, /api\.vatstack\.com/).to_return(
          status: 200,
          body: { valid: true, country_code: "DE", vat_number: "DE123456789" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_tax_id_pro_mocks
        # Tax ID Pro validation mocks
        WebMock.stub_request(:any, /api\.taxidpro\.com/).to_return(
          status: 200,
          body: { valid: true, ein: "12-3456789" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_discord_mocks
        # Discord API mocks
        WebMock.stub_request(:any, /discord\.com\/api/).to_return(
          status: 200,
          body: { id: "test_discord_#{SecureRandom.hex(8)}", name: "Test Server" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_zoom_mocks
        # Zoom API mocks
        WebMock.stub_request(:any, /api\.zoom\.us/).to_return(
          status: 200,
          body: { id: "test_meeting_#{SecureRandom.hex(8)}", topic: "Test Meeting" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_google_mocks
        # Google Calendar API mocks
        WebMock.stub_request(:any, /googleapis\.com\/calendar/).to_return(
          status: 200,
          body: { id: "test_event_#{SecureRandom.hex(8)}", summary: "Test Event" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Google OAuth mocks
        WebMock.stub_request(:post, /oauth2\.googleapis\.com\/token/).to_return(
          status: 200,
          body: {
            access_token: "test_access_token_#{SecureRandom.hex(16)}",
            token_type: "Bearer",
            expires_in: 3600
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_openai_mocks
        # OpenAI API mocks
        WebMock.stub_request(:post, /api\.openai\.com/).to_return(
          status: 200,
          body: {
            id: "test_completion_#{SecureRandom.hex(8)}",
            choices: [{ text: "Test response from OpenAI" }]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_unsplash_mocks
        # Unsplash API mocks
        WebMock.stub_request(:get, /api\.unsplash\.com/).to_return(
          status: 200,
          body: {
            results: [
              { id: "test_photo_1", urls: { regular: "https://example.com/photo1.jpg" } },
              { id: "test_photo_2", urls: { regular: "https://example.com/photo2.jpg" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_dropbox_mocks
        # Dropbox API mocks
        WebMock.stub_request(:any, /api\.dropboxapi\.com/).to_return(
          status: 200,
          body: { id: "test_file_#{SecureRandom.hex(8)}", name: "test_file.pdf" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_easypost_mocks
        # EasyPost shipping API mocks
        WebMock.stub_request(:any, /api\.easypost\.com/).to_return(
          status: 200,
          body: {
            id: "shp_test_#{SecureRandom.hex(8)}",
            tracking_code: "TEST#{SecureRandom.hex(8).upcase}",
            rates: [{ rate: "5.99", carrier: "USPS", service: "Priority" }]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_exchange_rates_mocks
        # Open Exchange Rates API mocks
        WebMock.stub_request(:get, /openexchangerates\.org/).to_return(
          status: 200,
          body: {
            base: "USD",
            rates: {
              "EUR" => 0.85,
              "GBP" => 0.73,
              "JPY" => 110.0,
              "CAD" => 1.25
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

    def log_mock_status
        puts "\n" + "=" * 80
        puts "EXTERNAL SERVICE MOCKS ACTIVE"
        puts "=" * 80
        puts "The following services are being mocked:"
        puts "  • Stripe (payments)"
        puts "  • PayPal (payments)"
        puts "  • Braintree (payments)"
        puts "  • Circle (payments)"
        puts "  • AWS S3 (storage)"
        puts "  • SendGrid (email)"
        puts "  • Resend (email)"
        puts "  • TaxJar (tax calculations)"
        puts "  • VATStack (VAT validation)"
        puts "  • Discord (social)"
        puts "  • Zoom (video)"
        puts "  • Google APIs (calendar, oauth)"
        puts "  • OpenAI (AI)"
        puts "  • Unsplash (images)"
        puts "  • Dropbox (storage)"
        puts "  • EasyPost (shipping)"
        puts "  • Open Exchange Rates (currency)"
        puts "=" * 80 + "\n"
      end
  end
end
