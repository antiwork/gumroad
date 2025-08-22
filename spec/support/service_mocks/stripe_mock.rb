# frozen_string_literal: true

# StripeMock provides comprehensive mocking for Stripe API
module StripeMock
  class << self
    def setup!
      return unless defined?(WebMock)

      setup_customer_mocks
      setup_charge_mocks
      setup_payment_intent_mocks
      setup_subscription_mocks
      setup_connect_mocks
      setup_webhook_mocks
      setup_balance_mocks
      setup_payout_mocks
      setup_refund_mocks
    end

    private
      def setup_customer_mocks
        # Create customer
        WebMock.stub_request(:post, "https://api.stripe.com/v1/customers").to_return(
          status: 200,
          body: stripe_customer_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Retrieve customer
        WebMock.stub_request(:get, %r{https://api.stripe.com/v1/customers/cus_}).to_return(
          status: 200,
          body: stripe_customer_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # List customers
        WebMock.stub_request(:get, "https://api.stripe.com/v1/customers").to_return(
          status: 200,
          body: { object: "list", data: [stripe_customer_response] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_charge_mocks
        # Create charge
        WebMock.stub_request(:post, "https://api.stripe.com/v1/charges").to_return(
          status: 200,
          body: stripe_charge_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Retrieve charge
        WebMock.stub_request(:get, %r{https://api.stripe.com/v1/charges/ch_}).to_return(
          status: 200,
          body: stripe_charge_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_payment_intent_mocks
        # Create payment intent
        WebMock.stub_request(:post, "https://api.stripe.com/v1/payment_intents").to_return(
          status: 200,
          body: stripe_payment_intent_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Confirm payment intent
        WebMock.stub_request(:post, %r{https://api.stripe.com/v1/payment_intents/pi_.*/confirm}).to_return(
          status: 200,
          body: stripe_payment_intent_response("succeeded").to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Retrieve payment intent
        WebMock.stub_request(:get, %r{https://api.stripe.com/v1/payment_intents/pi_}).to_return(
          status: 200,
          body: stripe_payment_intent_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_subscription_mocks
        # Create subscription
        WebMock.stub_request(:post, "https://api.stripe.com/v1/subscriptions").to_return(
          status: 200,
          body: stripe_subscription_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Retrieve subscription
        WebMock.stub_request(:get, %r{https://api.stripe.com/v1/subscriptions/sub_}).to_return(
          status: 200,
          body: stripe_subscription_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Cancel subscription
        WebMock.stub_request(:delete, %r{https://api.stripe.com/v1/subscriptions/sub_}).to_return(
          status: 200,
          body: stripe_subscription_response("canceled").to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_connect_mocks
        # OAuth token exchange
        WebMock.stub_request(:post, "https://connect.stripe.com/oauth/token").to_return(
          status: 200,
          body: {
            access_token: "sk_test_#{SecureRandom.hex(24)}",
            livemode: false,
            refresh_token: "rt_test_#{SecureRandom.hex(24)}",
            token_type: "bearer",
            stripe_publishable_key: "pk_test_#{SecureRandom.hex(24)}",
            stripe_user_id: "acct_test#{SecureRandom.hex(8)}",
            scope: "read_write"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Account creation
        WebMock.stub_request(:post, "https://api.stripe.com/v1/accounts").to_return(
          status: 200,
          body: stripe_account_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Account retrieval
        WebMock.stub_request(:get, %r{https://api.stripe.com/v1/accounts/acct_}).to_return(
          status: 200,
          body: stripe_account_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_webhook_mocks
        # Webhook endpoint creation
        WebMock.stub_request(:post, "https://api.stripe.com/v1/webhook_endpoints").to_return(
          status: 200,
          body: {
            id: "we_test_#{SecureRandom.hex(16)}",
            object: "webhook_endpoint",
            api_version: "2020-08-27",
            application: nil,
            created: Time.now.to_i,
            description: "Test webhook",
            enabled_events: ["*"],
            livemode: false,
            metadata: {},
            status: "enabled",
            url: "https://test.example.com/webhooks/stripe"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_balance_mocks
        # Balance retrieval
        WebMock.stub_request(:get, "https://api.stripe.com/v1/balance").to_return(
          status: 200,
          body: {
            object: "balance",
            available: [
              { amount: 1000000, currency: "usd", source_types: { card: 1000000 } }
            ],
            connect_reserved: [
              { amount: 0, currency: "usd" }
            ],
            livemode: false,
            pending: [
              { amount: 500000, currency: "usd", source_types: { card: 500000 } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_payout_mocks
        # Create payout
        WebMock.stub_request(:post, "https://api.stripe.com/v1/payouts").to_return(
          status: 200,
          body: stripe_payout_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Retrieve payout
        WebMock.stub_request(:get, %r{https://api.stripe.com/v1/payouts/po_}).to_return(
          status: 200,
          body: stripe_payout_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      def setup_refund_mocks
        # Create refund
        WebMock.stub_request(:post, "https://api.stripe.com/v1/refunds").to_return(
          status: 200,
          body: stripe_refund_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

        # Retrieve refund
        WebMock.stub_request(:get, %r{https://api.stripe.com/v1/refunds/re_}).to_return(
          status: 200,
          body: stripe_refund_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      # Response generators

      def stripe_customer_response
        {
          id: "cus_test_#{SecureRandom.hex(14)}",
          object: "customer",
          address: nil,
          balance: 0,
          created: Time.now.to_i,
          currency: "usd",
          default_source: nil,
          delinquent: false,
          description: "Test Customer",
          discount: nil,
          email: "test@example.com",
          invoice_prefix: "TEST",
          invoice_settings: {
            custom_fields: nil,
            default_payment_method: nil,
            footer: nil
          },
          livemode: false,
          metadata: {},
          name: "Test Customer",
          next_invoice_sequence: 1,
          phone: nil,
          preferred_locales: [],
          shipping: nil,
          tax_exempt: "none"
        }
      end

      def stripe_charge_response(status = "succeeded")
        {
          id: "ch_test_#{SecureRandom.hex(24)}",
          object: "charge",
          amount: 1000,
          amount_captured: 1000,
          amount_refunded: 0,
          application: nil,
          application_fee: nil,
          application_fee_amount: nil,
          balance_transaction: "txn_test_#{SecureRandom.hex(24)}",
          billing_details: {
            address: { city: nil, country: nil, line1: nil, line2: nil, postal_code: nil, state: nil },
            email: nil,
            name: nil,
            phone: nil
          },
          calculated_statement_descriptor: nil,
          captured: true,
          created: Time.now.to_i,
          currency: "usd",
          customer: "cus_test_#{SecureRandom.hex(14)}",
          description: "Test Charge",
          disputed: false,
          failure_code: nil,
          failure_message: nil,
          fraud_details: {},
          invoice: nil,
          livemode: false,
          metadata: {},
          on_behalf_of: nil,
          order: nil,
          outcome: {
            network_status: "approved_by_network",
            reason: nil,
            risk_level: "normal",
            risk_score: 32,
            seller_message: "Payment complete.",
            type: "authorized"
          },
          paid: true,
          payment_intent: nil,
          payment_method: "card_test_#{SecureRandom.hex(24)}",
          payment_method_details: {
            card: {
              brand: "visa",
              checks: {
                address_line1_check: nil,
                address_postal_code_check: nil,
                cvc_check: "pass"
              },
              country: "US",
              exp_month: 12,
              exp_year: 2025,
              fingerprint: SecureRandom.hex(16),
              funding: "credit",
              installments: nil,
              last4: "4242",
              network: "visa",
              three_d_secure: nil,
              wallet: nil
            },
            type: "card"
          },
          receipt_email: nil,
          receipt_number: nil,
          receipt_url: "https://pay.stripe.com/receipts/test_#{SecureRandom.hex(32)}",
          refunded: false,
          refunds: { object: "list", data: [], has_more: false, url: "/v1/charges/ch_test/refunds" },
          review: nil,
          shipping: nil,
          source_transfer: nil,
          statement_descriptor: nil,
          statement_descriptor_suffix: nil,
          status: status,
          transfer_data: nil,
          transfer_group: nil
        }
      end

      def stripe_payment_intent_response(status = "requires_payment_method")
        {
          id: "pi_test_#{SecureRandom.hex(24)}",
          object: "payment_intent",
          amount: 1000,
          amount_capturable: 0,
          amount_received: status == "succeeded" ? 1000 : 0,
          application: nil,
          application_fee_amount: nil,
          canceled_at: nil,
          cancellation_reason: nil,
          capture_method: "automatic",
          charges: { object: "list", data: [], has_more: false, url: "/v1/charges?payment_intent=pi_test" },
          client_secret: "pi_test_#{SecureRandom.hex(24)}_secret_#{SecureRandom.hex(24)}",
          confirmation_method: "automatic",
          created: Time.now.to_i,
          currency: "usd",
          customer: nil,
          description: nil,
          invoice: nil,
          last_payment_error: nil,
          livemode: false,
          metadata: {},
          next_action: nil,
          on_behalf_of: nil,
          payment_method: nil,
          payment_method_options: {},
          payment_method_types: ["card"],
          receipt_email: nil,
          review: nil,
          setup_future_usage: nil,
          shipping: nil,
          statement_descriptor: nil,
          statement_descriptor_suffix: nil,
          status: status,
          transfer_data: nil,
          transfer_group: nil
        }
      end

      def stripe_subscription_response(status = "active")
        {
          id: "sub_test_#{SecureRandom.hex(24)}",
          object: "subscription",
          application_fee_percent: nil,
          billing_cycle_anchor: Time.now.to_i,
          billing_thresholds: nil,
          cancel_at: nil,
          cancel_at_period_end: false,
          canceled_at: status == "canceled" ? Time.now.to_i : nil,
          collection_method: "charge_automatically",
          created: Time.now.to_i,
          current_period_end: (Time.now + 30.days).to_i,
          current_period_start: Time.now.to_i,
          customer: "cus_test_#{SecureRandom.hex(14)}",
          days_until_due: nil,
          default_payment_method: nil,
          default_source: nil,
          default_tax_rates: [],
          discount: nil,
          ended_at: nil,
          items: {
            object: "list",
            data: [{
              id: "si_test_#{SecureRandom.hex(24)}",
              object: "subscription_item",
              billing_thresholds: nil,
              created: Time.now.to_i,
              metadata: {},
              plan: {
                id: "plan_test_#{SecureRandom.hex(24)}",
                object: "plan",
                active: true,
                aggregate_usage: nil,
                amount: 999,
                amount_decimal: "999",
                billing_scheme: "per_unit",
                created: Time.now.to_i,
                currency: "usd",
                interval: "month",
                interval_count: 1,
                livemode: false,
                metadata: {},
                nickname: nil,
                product: "prod_test_#{SecureRandom.hex(24)}",
                tiers_mode: nil,
                transform_usage: nil,
                trial_period_days: nil,
                usage_type: "licensed"
              },
              price: {
                id: "price_test_#{SecureRandom.hex(24)}",
                object: "price",
                active: true,
                billing_scheme: "per_unit",
                created: Time.now.to_i,
                currency: "usd",
                livemode: false,
                lookup_key: nil,
                metadata: {},
                nickname: nil,
                product: "prod_test_#{SecureRandom.hex(24)}",
                recurring: {
                  aggregate_usage: nil,
                  interval: "month",
                  interval_count: 1,
                  trial_period_days: nil,
                  usage_type: "licensed"
                },
                tax_behavior: "unspecified",
                tiers_mode: nil,
                transform_quantity: nil,
                type: "recurring",
                unit_amount: 999,
                unit_amount_decimal: "999"
              },
              quantity: 1,
              subscription: "sub_test",
              tax_rates: []
            }],
            has_more: false,
            url: "/v1/subscription_items?subscription=sub_test"
          },
          latest_invoice: "in_test_#{SecureRandom.hex(24)}",
          livemode: false,
          metadata: {},
          next_pending_invoice_item_invoice: nil,
          pause_collection: nil,
          pending_invoice_item_interval: nil,
          pending_setup_intent: nil,
          pending_update: nil,
          plan: nil,
          quantity: nil,
          schedule: nil,
          start_date: Time.now.to_i,
          status: status,
          tax_percent: nil,
          transfer_data: nil,
          trial_end: nil,
          trial_start: nil
        }
      end

      def stripe_account_response
        {
          id: "acct_test#{SecureRandom.hex(8)}",
          object: "account",
          business_profile: {
            mcc: nil,
            name: "Test Business",
            product_description: nil,
            support_address: nil,
            support_email: "support@test.com",
            support_phone: nil,
            support_url: nil,
            url: nil
          },
          business_type: "individual",
          capabilities: {
            card_payments: "active",
            transfers: "active"
          },
          charges_enabled: true,
          country: "US",
          created: Time.now.to_i,
          default_currency: "usd",
          details_submitted: true,
          email: "test@example.com",
          external_accounts: {
            object: "list",
            data: [],
            has_more: false,
            url: "/v1/accounts/acct_test/external_accounts"
          },
          metadata: {},
          payouts_enabled: true,
          requirements: {
            current_deadline: nil,
            currently_due: [],
            disabled_reason: nil,
            errors: [],
            eventually_due: [],
            past_due: [],
            pending_verification: []
          },
          settings: {
            billing: {
              statement_descriptor: "TEST",
              statement_descriptor_kana: nil,
              statement_descriptor_kanji: nil
            },
            card_issuing: {
              tos_acceptance: {
                date: nil,
                ip: nil
              }
            },
            card_payments: {
              decline_on: {
                avs_failure: false,
                cvc_failure: false
              },
              statement_descriptor_prefix: nil
            },
            dashboard: {
              display_name: "Test Account",
              timezone: "America/Los_Angeles"
            },
            payments: {
              statement_descriptor: "TEST",
              statement_descriptor_kana: nil,
              statement_descriptor_kanji: nil
            },
            payouts: {
              debit_negative_balances: true,
              schedule: {
                delay_days: 2,
                interval: "daily"
              },
              statement_descriptor: nil
            }
          },
          tos_acceptance: {
            date: Time.now.to_i,
            ip: "127.0.0.1",
            user_agent: "Test/1.0"
          },
          type: "standard"
        }
      end

      def stripe_payout_response(status = "paid")
        {
          id: "po_test_#{SecureRandom.hex(24)}",
          object: "payout",
          amount: 100000,
          arrival_date: (Time.now + 2.days).to_i,
          automatic: true,
          balance_transaction: "txn_test_#{SecureRandom.hex(24)}",
          created: Time.now.to_i,
          currency: "usd",
          description: "Test Payout",
          destination: "ba_test_#{SecureRandom.hex(24)}",
          failure_balance_transaction: nil,
          failure_code: nil,
          failure_message: nil,
          livemode: false,
          metadata: {},
          method: "standard",
          original_payout: nil,
          reversed_by: nil,
          source_type: "card",
          statement_descriptor: nil,
          status: status,
          type: "bank_account"
        }
      end

      def stripe_refund_response(status = "succeeded")
        {
          id: "re_test_#{SecureRandom.hex(24)}",
          object: "refund",
          amount: 500,
          balance_transaction: "txn_test_#{SecureRandom.hex(24)}",
          charge: "ch_test_#{SecureRandom.hex(24)}",
          created: Time.now.to_i,
          currency: "usd",
          metadata: {},
          payment_intent: "pi_test_#{SecureRandom.hex(24)}",
          reason: "requested_by_customer",
          receipt_number: nil,
          source_transfer_reversal: nil,
          status: status,
          transfer_reversal: nil
        }
      end
  end
end
