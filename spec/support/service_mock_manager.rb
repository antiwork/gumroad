# frozen_string_literal: true

# ServiceMockManager handles mocking of external services for tests
module ServiceMockManager
  class << self
    def enable_all_mocks!
      enable_stripe_mocks!
      enable_aws_mocks!
      enable_paypal_mocks!
      enable_braintree_mocks!
      enable_external_api_mocks!
      disable_balance_enforcement!
    end

    def disable_all_mocks!
      # This will be handled by WebMock reset in test teardown
    end

    private

    # Mock Stripe API calls
    def enable_stripe_mocks!
      # Mock Stripe Balance API
      WebMock.stub_request(:get, "https://api.stripe.com/v1/balance")
        .to_return(
          status: 200,
          body: {
            available: [{ amount: 1_000_000, currency: "usd" }],
            pending: [{ amount: 0, currency: "usd" }]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Mock Stripe Charges API
      WebMock.stub_request(:post, "https://api.stripe.com/v1/payment_intents")
        .to_return(
          status: 200,
          body: {
            id: "pi_test_1234567890",
            status: "succeeded",
            amount: 999_999_99,
            currency: "usd"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Mock other Stripe endpoints as needed
      WebMock.stub_request(:get, %r{https://api\.stripe\.com/.*})
        .to_return(
          status: 200,
          body: { id: "test_stripe_response" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      WebMock.stub_request(:post, %r{https://api\.stripe\.com/.*})
        .to_return(
          status: 200,
          body: { id: "test_stripe_response" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    # Mock AWS services
    def enable_aws_mocks!
      # Mock S3 operations
      WebMock.stub_request(:put, %r{https://.*\.s3\.amazonaws\.com/.*})
        .to_return(status: 200, body: "", headers: {})

      WebMock.stub_request(:get, %r{https://.*\.s3\.amazonaws\.com/.*})
        .to_return(status: 200, body: "mock file content", headers: {})

      WebMock.stub_request(:delete, %r{https://.*\.s3\.amazonaws\.com/.*})
        .to_return(status: 204, body: "", headers: {})

      # Mock other AWS services
      WebMock.stub_request(:post, %r{https://.*\.amazonaws\.com/.*})
        .to_return(status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" })
    end

    # Mock PayPal API
    def enable_paypal_mocks!
      # Mock PayPal OAuth
      WebMock.stub_request(:post, %r{https://api\.paypal\.com/v1/oauth2/token})
        .to_return(
          status: 200,
          body: { access_token: "mock_paypal_token", token_type: "Bearer" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Mock PayPal API calls
      WebMock.stub_request(:any, %r{https://api\.paypal\.com/.*})
        .to_return(
          status: 200,
          body: { id: "mock_paypal_response", status: "COMPLETED" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Mock PayPal sandbox
      WebMock.stub_request(:any, %r{https://api\.sandbox\.paypal\.com/.*})
        .to_return(
          status: 200,
          body: { id: "mock_paypal_sandbox_response" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    # Mock Braintree
    def enable_braintree_mocks!
      # Braintree typically uses the SDK, so we'll need to mock the classes
      return unless defined?(Braintree)

      # Mock Braintree configuration
      allow(Braintree::Configuration).to receive(:logger=)

      # These would need to be more specific based on actual Braintree usage in tests
    end

    # Mock external APIs
    def enable_external_api_mocks!
      # Mock Dropbox API
      WebMock.stub_request(:any, %r{https://api\.dropboxapi\.com/.*})
        .to_return(status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock SendGrid API
      WebMock.stub_request(:post, %r{https://api\.sendgrid\.com/.*})
        .to_return(status: 202, body: "", headers: {})

      # Mock EasyPost API
      WebMock.stub_request(:any, %r{https://api\.easypost\.com/.*})
        .to_return(status: 200, body: { id: "mock_easypost_response" }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock TaxJar API
      WebMock.stub_request(:any, %r{https://api\.taxjar\.com/.*})
        .to_return(status: 200, body: { tax: { amount_to_collect: 0 } }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock VATStack API
      WebMock.stub_request(:any, %r{https://api\.vatstack\.com/.*})
        .to_return(status: 200, body: { valid: true }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock other APIs
      WebMock.stub_request(:any, %r{https://api\.unsplash\.com/.*})
        .to_return(status: 200, body: { id: "mock_unsplash_response" }.to_json, headers: { "Content-Type" => "application/json" })

      WebMock.stub_request(:any, %r{https://openexchangerates\.org/.*})
        .to_return(status: 200, body: { rates: { USD: 1.0 } }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock Discord API
      WebMock.stub_request(:any, %r{https://discord\.com/api/.*})
        .to_return(status: 200, body: { id: "mock_discord_response" }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock Zoom API
      WebMock.stub_request(:any, %r{https://api\.zoom\.us/.*})
        .to_return(status: 200, body: { id: "mock_zoom_response" }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock Google APIs
      WebMock.stub_request(:any, %r{https://.*\.googleapis\.com/.*})
        .to_return(status: 200, body: { id: "mock_google_response" }.to_json, headers: { "Content-Type" => "application/json" })

      # Mock OpenAI API
      WebMock.stub_request(:any, %r{https://api\.openai\.com/.*})
        .to_return(status: 200, body: { id: "mock_openai_response" }.to_json, headers: { "Content-Type" => "application/json" })
    end

    # Disable Stripe balance enforcement
    def disable_balance_enforcement!
      return unless defined?(StripeBalanceEnforcer)

      allow(StripeBalanceEnforcer).to receive(:ensure_sufficient_balance).and_return(true)
    end
  end
end
