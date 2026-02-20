# frozen_string_literal: true

require "spec_helper"

describe "Checkout with Payment Request API", :js, type: :system do
  # Builds a minimal Stripe Payment Request mock and injects it via CDP so it
  # runs before any other scripts on *every subsequent page load*.  Call this
  # once before the first `visit` inside a test (or in a `before` block after
  # `mock_payment_request_availability` has been called).
  def mock_payment_request_availability(apple_pay: false, google_pay: false)
    apple_pay_js  = apple_pay  ? "true" : "false"
    google_pay_js = google_pay ? "true" : "false"

    apple_pay_session_mock = apple_pay ? <<~JS : ""
      window.ApplePaySession = window.ApplePaySession || {
        canMakePayments: function() { return true; },
        supportsVersion: function() { return true; },
        STATUS_SUCCESS: 0,
        STATUS_FAILURE: 1,
        STATUS_INVALID_BILLING_POSTAL_ADDRESS: 2,
        STATUS_INVALID_SHIPPING_POSTAL_ADDRESS: 3,
        STATUS_INVALID_SHIPPING_CONTACT: 4,
        STATUS_PIN_INCORRECT: 5,
        STATUS_PIN_LOCKOUT: 6,
        STATUS_PIN_REQUIRED: 7
      };
    JS

    @payment_request_mock_script = <<~JS
      (function() {
        #{apple_pay_session_mock}

        // Build a fake PaymentRequest object whose canMakePayment resolves to
        // the desired payment methods.
        function makeFakePaymentRequest(options) {
          const listeners = {};
          const pr = {
            _options: options,
            canMakePayment: function() {
              return Promise.resolve({ applePay: #{apple_pay_js}, googlePay: #{google_pay_js} });
            },
            show: function() {
              return Promise.reject(new Error('Payment request: not supported in test environment'));
            },
            abort: function() {},
            update: function() {},
            on: function(event, handler) {
              listeners[event] = listeners[event] || [];
              listeners[event].push(handler);
            },
            off: function(event, handler) {
              if (!listeners[event]) return;
              listeners[event] = listeners[event].filter(function(h) { return h !== handler; });
            },
            emit: function(event, data) {
              (listeners[event] || []).forEach(function(h) { h(data); });
            }
          };
          // Simulate cancel after show() rejects so state machine can reset
          const origShow = pr.show.bind(pr);
          pr.show = function() {
            return origShow().catch(function(err) {
              setTimeout(function() { pr.emit('cancel'); }, 50);
              throw err;
            });
          };
          return pr;
        }

        // Build a fake Stripe instance that wraps the real one when available,
        // but patches paymentRequest to return our fake.
        function makeFakeStripe(publicKey, opts) {
          const self = {
            paymentRequest: makeFakePaymentRequest,
            elements: function(opts) {
              // Minimal Elements stub sufficient for the payment form to render.
              return {
                create: function(type, opts) {
                  const el = {
                    _type: type,
                    mount: function() {},
                    unmount: function() {},
                    destroy: function() {},
                    on: function() {},
                    off: function() {},
                    update: function() {},
                    focus: function() {},
                    blur: function() {},
                    clear: function() {}
                  };
                  return el;
                },
                update: function() {},
                getElement: function() { return null; },
                fetchUpdates: function() { return Promise.resolve({}); }
              };
            },
            confirmCardPayment: function() {
              return Promise.resolve({ paymentIntent: { status: 'succeeded' } });
            },
            confirmPayment: function() {
              return Promise.resolve({ paymentIntent: { status: 'succeeded' } });
            },
            createToken: function() {
              return Promise.resolve({ token: { id: 'tok_test_mock' } });
            },
            createPaymentMethod: function() {
              return Promise.resolve({ paymentMethod: { id: 'pm_test_mock' } });
            },
            retrievePaymentIntent: function() {
              return Promise.resolve({ paymentIntent: null });
            },
            handleCardAction: function() {
              return Promise.resolve({ paymentIntent: { status: 'succeeded' } });
            }
          };
          return self;
        }

        // Override window.Stripe with our mock factory (before stripe.js loads).
        window.Stripe = makeFakeStripe;
      })();
    JS
  end

  def inject_payment_request_mock
    return unless @payment_request_mock_script

    # Register script to execute before page scripts on next navigation.
    # This CDP command works even before any page has been visited.
    @cdp_script_identifiers ||= []
    result = page.driver.browser.execute_cdp(
      'Page.addScriptToEvaluateOnNewDocument',
      source: @payment_request_mock_script
    )
    @cdp_script_identifiers << result["identifier"] if result&.dig("identifier")

    # Also apply immediately on the current page if one is loaded
    begin
      page.execute_script(@payment_request_mock_script)
    rescue StandardError
      # No page loaded yet — that's fine, the CDP script will run on the next visit
    end
  rescue StandardError => e
    warn "Warning: Payment request mock injection failed: #{e.message}"
  end

  def clear_payment_request_mocks
    (@cdp_script_identifiers || []).each do |id|
      begin
        page.driver.browser.execute_cdp(
          'Page.removeScriptToEvaluateOnNewDocument',
          identifier: id
        )
      rescue StandardError
      end
    end
    @cdp_script_identifiers = nil
  rescue StandardError
  end

  let(:product) { create(:product, price_cents: 2000, name: "Test Product") }

  after do
    clear_payment_request_mocks
  end

  context "Apple Pay" do
    before do
      mock_payment_request_availability(apple_pay: true, google_pay: false)
      inject_payment_request_mock
    end

    it "allows selecting Apple Pay" do
      visit product.long_url
      add_to_cart(product)

      expect(page).to have_field("Apple Pay", type: "radio", wait: 10)

      expect(page).to have_text("Apple Pay")

      apple_pay_label = find("label", text: /\AApple Pay\z/)
      expect(apple_pay_label).to have_selector("span.brand-icon-apple, svg, img, [class*='apple'], [class*='ApplePay']")

      choose "Apple Pay"

      expect(page).to have_checked_field("Apple Pay", wait: 5)
      expect(page).not_to have_text("Card information")
      expect(page).to have_button("Pay", wait: 5)
    end

    it "can switch between Apple Pay and card" do
      visit product.long_url
      add_to_cart(product)

      choose "Apple Pay"

      expect(page).not_to have_text("Card information")

      choose "Card"

      expect(page).to have_text("Card information", wait: 5)
    end

    it "returns to input state when payment is cancelled" do
      visit product.long_url
      add_to_cart(product)

      fill_in "Email address", with: "buyer@example.com"
      choose "Apple Pay"

      expect(page).to have_button("Pay", disabled: false)

      find_button("Pay").click

      expect(page).to have_button("Pay", wait: 10)
    end

    it "shows Pay button and email field when Apple Pay is selected" do
      visit product.long_url
      add_to_cart(product)

      choose "Apple Pay"

      expect(page).to have_field("Email address")
      expect(page).to have_button("Pay", wait: 5)
    end

    it "works with physical products" do
      physical_product = create(:product, :physical, price_cents: 3000)

      visit physical_product.long_url
      add_to_cart(physical_product)

      expect(page).to have_field("Apple Pay", type: "radio", wait: 10)

      choose "Apple Pay"

      expect(page).to have_button("Pay", wait: 5)
    end

    it "works with subscriptions" do
      subscription_product = create(:product, :membership, price_cents: 1500, subscription_duration: "monthly", is_tiered_membership: false)

      visit subscription_product.long_url
      add_to_cart(subscription_product)

      expect(page).to have_field("Apple Pay", type: "radio", wait: 10)

      choose "Apple Pay"

      expect(page).to have_button(text: /Pay|Subscribe/, wait: 5)
    end
  end

  context "Google Pay" do
    before do
      mock_payment_request_availability(apple_pay: false, google_pay: true)
      inject_payment_request_mock
    end

    it "allows selecting Google Pay" do
      visit product.long_url
      add_to_cart(product)

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)

      expect(page).to have_text("Google Pay")

      google_pay_label = find("label", text: /\AGoogle Pay\z/)
      expect(google_pay_label).to have_selector("span.brand-icon-google, svg, img, [class*='google'], [class*='GooglePay']")

      choose "Google Pay"

      expect(page).to have_checked_field("Google Pay", wait: 5)
      expect(page).not_to have_text("Card information")
      expect(page).to have_button("Pay", wait: 5)
    end

    it "can switch between Google Pay and card" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"

      expect(page).not_to have_text("Card information")

      choose "Card"

      expect(page).to have_text("Card information", wait: 5)
    end

    it "returns to input state when payment is cancelled" do
      visit product.long_url
      add_to_cart(product)

      fill_in "Email address", with: "buyer@example.com"
      choose "Google Pay"

      expect(page).to have_button("Pay", disabled: false)

      find_button("Pay").click

      expect(page).to have_button("Pay", wait: 10)
    end

    it "shows Pay button and email field when Google Pay is selected" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"

      expect(page).to have_field("Email address")
      expect(page).to have_button("Pay", wait: 5)
    end

    it "works with physical products" do
      physical_product = create(:product, :physical, price_cents: 3000)

      visit physical_product.long_url
      add_to_cart(physical_product)

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)

      choose "Google Pay"

      expect(page).to have_button("Pay", wait: 5)
    end

    it "works with subscriptions" do
      subscription_product = create(:product, :membership, price_cents: 1500, subscription_duration: "monthly", is_tiered_membership: false)

      visit subscription_product.long_url
      add_to_cart(subscription_product)

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)

      choose "Google Pay"

      expect(page).to have_button(text: /Pay|Subscribe/, wait: 5)
    end
  end

  context "both Apple Pay and Google Pay available" do
    before do
      mock_payment_request_availability(apple_pay: true, google_pay: true)
      inject_payment_request_mock
    end

    # When both are available, Stripe's payment request shows Google Pay label
    # (googlePay takes precedence in the component's isGooglePay check)
    it "shows payment request option and card" do
      visit product.long_url
      add_to_cart(product)

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)
      expect(page).to have_field("Card", type: "radio")
    end

    it "can switch between payment request and card" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"
      expect(page).to have_checked_field("Google Pay")
      expect(page).not_to have_text("Card information")

      choose "Card"
      expect(page).to have_checked_field("Card")
      expect(page).to have_text("Card information", wait: 5)
    end
  end

  context "no payment request methods available" do
    before do
      mock_payment_request_availability(apple_pay: false, google_pay: false)
      inject_payment_request_mock
    end

    it "only shows credit card option" do
      visit product.long_url
      add_to_cart(product)
      expect(page).not_to have_field("Google Pay", type: "radio")
      expect(page).not_to have_field("Apple Pay", type: "radio")
      expect(page).not_to have_field("Google Pay", type: "radio")
      # When no payment request methods are available, card is shown without radio (single option)
      expect(page).not_to have_field("Card", type: "radio")
      expect(page).to have_selector("[aria-label='Card information']", wait: 10)
    end
  end
end
