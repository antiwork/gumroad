# frozen_string_literal: true

module StripeApiStubs
  MOCK_PAYMENT_METHOD_ID = "pm_test_mock_payment_method"
  MOCK_CUSTOMER_ID = "cus_test_mock_customer"
  MOCK_PAYMENT_INTENT_ID = "pi_test_mock_payment_intent"
  MOCK_CHARGE_ID = "ch_test_mock_charge"
  MOCK_ACCOUNT_ID = "acct_test_mock_account"
  MOCK_SETUP_INTENT_ID = "seti_test_mock_setup_intent"

  module_function

  def stub_all_stripe_requests
    stub_balance_retrieve
    stub_payment_methods
    stub_customers
    stub_payment_intents
    stub_charges
    stub_accounts
    stub_setup_intents
    stub_tokens
    stub_files
  end

  def stub_balance_retrieve
    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/balance})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          object: "balance",
          available: [
            { amount: 1_000_000_00, currency: "usd", source_types: { card: 1_000_000_00 } }
          ],
          pending: [
            { amount: 0, currency: "usd", source_types: { card: 0 } }
          ],
          livemode: false
        }.to_json
      )
  end

  def stub_payment_methods
    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/payment_methods})
      .to_return { |request| payment_method_response(request) }

    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/payment_methods/pm_})
      .to_return { |request| payment_method_response(request) }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/payment_methods/pm_.+/attach})
      .to_return { |request| payment_method_response(request) }
  end

  def stub_customers
    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/customers})
      .to_return { |_request| customer_response }

    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/customers/cus_})
      .to_return { |_request| customer_response }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/customers/cus_})
      .to_return { |_request| customer_response }

    WebMock.stub_request(:delete, %r{api\.stripe\.com/v1/customers/cus_})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { id: MOCK_CUSTOMER_ID, object: "customer", deleted: true }.to_json
      )
  end

  def stub_payment_intents
    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/payment_intents})
      .to_return { |request| payment_intent_response(request) }

    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/payment_intents/pi_})
      .to_return { |request| payment_intent_response(request) }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/payment_intents/pi_.+/confirm})
      .to_return { |request| payment_intent_response(request, status: "succeeded") }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/payment_intents/pi_.+/cancel})
      .to_return { |request| payment_intent_response(request, status: "canceled") }
  end

  def stub_charges
    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/charges/ch_})
      .to_return { |_request| charge_response }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/charges})
      .to_return { |_request| charge_response }
  end

  def stub_accounts
    WebMock.stub_request(:post, "https://api.stripe.com/v1/accounts")
      .to_return { |_request| account_response }

    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/accounts/acct_})
      .to_return { |_request| account_response(charges_enabled: true) }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/accounts/acct_})
      .to_return { |_request| account_response(charges_enabled: true) }

    WebMock.stub_request(:delete, %r{api\.stripe\.com/v1/accounts/acct_})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { id: MOCK_ACCOUNT_ID, object: "account", deleted: true }.to_json
      )
  end

  def stub_setup_intents
    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/setup_intents})
      .to_return { |_request| setup_intent_response }

    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/setup_intents/seti_})
      .to_return { |_request| setup_intent_response }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/setup_intents/seti_.+/confirm})
      .to_return { |_request| setup_intent_response(status: "succeeded") }

    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/setup_intents/seti_.+/cancel})
      .to_return { |_request| setup_intent_response(status: "canceled") }
  end

  def stub_tokens
    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/tokens})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "tok_test_mock_token",
          object: "token",
          card: {
            id: "card_test_mock",
            object: "card",
            brand: "visa",
            country: "US",
            last4: "4242",
            exp_month: 12,
            exp_year: Time.current.year + 1,
            fingerprint: "test_fingerprint",
            funding: "debit",
            address_zip: "12345"
          },
          type: "card",
          livemode: false
        }.to_json
      )

    WebMock.stub_request(:get, %r{api\.stripe\.com/v1/tokens/tok_})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "tok_test_mock_token",
          object: "token",
          card: {
            id: "card_test_mock",
            object: "card",
            brand: "visa",
            country: "US",
            last4: "4242",
            exp_month: 12,
            exp_year: Time.current.year + 1,
            fingerprint: "test_fingerprint",
            funding: "debit",
            address_zip: "12345"
          },
          type: "card",
          livemode: false
        }.to_json
      )
  end

  def stub_files
    WebMock.stub_request(:post, %r{api\.stripe\.com/v1/files})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "file_test_mock",
          object: "file",
          purpose: "identity_document",
          size: 1024,
          type: "jpg"
        }.to_json
      )
  end

  def payment_method_response(_request)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: MOCK_PAYMENT_METHOD_ID,
        object: "payment_method",
        billing_details: {
          address: { city: nil, country: nil, line1: nil, line2: nil, postal_code: nil, state: nil },
          email: nil,
          name: nil,
          phone: nil
        },
        card: {
          brand: "visa",
          checks: { address_line1_check: nil, address_postal_code_check: nil, cvc_check: "pass" },
          country: "US",
          exp_month: 12,
          exp_year: Time.current.year + 1,
          fingerprint: "test_fingerprint",
          funding: "credit",
          last4: "4242",
          networks: { available: ["visa"], preferred: nil },
          three_d_secure_usage: { supported: true },
          wallet: nil
        },
        created: Time.current.to_i,
        customer: nil,
        livemode: false,
        type: "card"
      }.to_json
    }
  end

  def customer_response
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: MOCK_CUSTOMER_ID,
        object: "customer",
        balance: 0,
        created: Time.current.to_i,
        currency: nil,
        default_source: "card_test_mock",
        delinquent: false,
        description: nil,
        email: nil,
        invoice_prefix: "TEST",
        invoice_settings: { custom_fields: nil, default_payment_method: nil, footer: nil },
        livemode: false,
        metadata: {},
        name: nil,
        next_invoice_sequence: 1,
        phone: nil,
        preferred_locales: [],
        shipping: nil,
        tax_exempt: "none",
        sources: {
          object: "list",
          data: [
            {
              id: "card_test_mock",
              object: "card",
              brand: "visa",
              country: "US",
              exp_month: 12,
              exp_year: Time.current.year + 1,
              fingerprint: "test_fingerprint",
              funding: "debit",
              last4: "4242",
              address_zip: "12345"
            }
          ],
          has_more: false,
          total_count: 1,
          url: "/v1/customers/#{MOCK_CUSTOMER_ID}/sources"
        }
      }.to_json
    }
  end

  def payment_intent_response(_request, status: "requires_payment_method")
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: MOCK_PAYMENT_INTENT_ID,
        object: "payment_intent",
        amount: 1000,
        amount_received: status == "succeeded" ? 1000 : 0,
        currency: "usd",
        client_secret: "pi_test_secret_mock",
        confirmation_method: "automatic",
        created: Time.current.to_i,
        customer: nil,
        description: nil,
        latest_charge: status == "succeeded" ? MOCK_CHARGE_ID : nil,
        livemode: false,
        metadata: {},
        payment_method: MOCK_PAYMENT_METHOD_ID,
        payment_method_types: ["card"],
        status: status,
        transfer_data: nil,
        transfer_group: nil
      }.to_json
    }
  end

  def charge_response
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: MOCK_CHARGE_ID,
        object: "charge",
        amount: 1000,
        amount_captured: 1000,
        amount_refunded: 0,
        balance_transaction: "txn_test_mock",
        billing_details: {
          address: { city: nil, country: nil, line1: nil, line2: nil, postal_code: nil, state: nil },
          email: nil,
          name: nil,
          phone: nil
        },
        captured: true,
        created: Time.current.to_i,
        currency: "usd",
        customer: nil,
        description: nil,
        disputed: false,
        failure_code: nil,
        failure_message: nil,
        livemode: false,
        metadata: {},
        paid: true,
        payment_intent: MOCK_PAYMENT_INTENT_ID,
        payment_method: MOCK_PAYMENT_METHOD_ID,
        refunded: false,
        status: "succeeded"
      }.to_json
    }
  end

  def account_response(charges_enabled: false)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: MOCK_ACCOUNT_ID,
        object: "account",
        business_profile: {
          mcc: "5192",
          name: nil,
          product_description: "Test Product",
          support_email: nil,
          support_phone: nil,
          support_url: nil,
          url: "https://example.com"
        },
        business_type: "individual",
        capabilities: {
          card_payments: charges_enabled ? "active" : "pending",
          transfers: charges_enabled ? "active" : "pending"
        },
        charges_enabled: charges_enabled,
        country: "US",
        created: Time.current.to_i,
        default_currency: "usd",
        details_submitted: true,
        email: "test@example.com",
        external_accounts: { object: "list", data: [], has_more: false },
        individual: {
          first_name: "Test",
          last_name: "User",
          email: "test@example.com"
        },
        metadata: {},
        payouts_enabled: charges_enabled,
        type: "custom"
      }.to_json
    }
  end

  def setup_intent_response(status: "requires_payment_method")
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: MOCK_SETUP_INTENT_ID,
        object: "setup_intent",
        client_secret: "seti_test_secret_mock",
        created: Time.current.to_i,
        customer: MOCK_CUSTOMER_ID,
        description: nil,
        livemode: false,
        metadata: {},
        payment_method: MOCK_PAYMENT_METHOD_ID,
        payment_method_types: ["card"],
        status: status,
        usage: "off_session"
      }.to_json
    }
  end
end
