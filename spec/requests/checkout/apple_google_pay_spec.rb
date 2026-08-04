# frozen_string_literal: true

require "spec_helper"

describe "Checkout with Payment Request API", :js, type: :system do
  # Builds a minimal Stripe Payment Request mock and injects it via CDP so it
  # runs before any other scripts on every subsequent page load.
  def inject_payment_request_mock(apple_pay: false, google_pay: false)
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

    script = <<~JS
      (function() {
        #{apple_pay_session_mock}

        // Build a fake PaymentRequest object whose canMakePayment resolves to
        // the desired payment methods.
        function makeFakePaymentRequest(options) {
          const listeners = {};
          const pr = {
            _options: options,
            canMakePayment: function() {
              return Promise.resolve({ applePay: #{apple_pay}, googlePay: #{google_pay} });
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

        // Wrap the REAL Stripe factory, patching only paymentRequest. A full replacement
        // (the previous approach) breaks the Payment Element: @stripe/stripe-js's loadStripe
        // short-circuits onto a pre-existing window.Stripe without ever loading js.stripe.com,
        // and a stubbed elements() renders an empty element — the "Card information" fieldset
        // then has zero height and every visibility assertion on it fails.
        function wrapStripeFactory(realFactory) {
          const wrapped = function(publicKey, opts) {
            const instance = realFactory(publicKey, opts);
            instance.paymentRequest = makeFakePaymentRequest;
            return instance;
          };
          for (const key in realFactory) {
            try { wrapped[key] = realFactory[key]; } catch (e) {}
          }
          return wrapped;
        }

        if (window.Stripe) {
          window.Stripe = wrapStripeFactory(window.Stripe);
        } else {
          // Keep window.Stripe undefined until js.stripe.com assigns the real factory, so
          // loadStripe still injects the script; wrap the factory the moment it lands.
          let stored;
          Object.defineProperty(window, 'Stripe', {
            configurable: true,
            get: function() { return stored; },
            set: function(realFactory) { stored = wrapStripeFactory(realFactory); }
          });
        }
      })();
    JS

    @cdp_script_identifier = page.driver.browser.execute_cdp(
      "Page.addScriptToEvaluateOnNewDocument",
      source: script
    ).fetch("identifier")

    begin
      page.execute_script(script)
    rescue StandardError
      # No page loaded yet — that's fine, the CDP script will run on the next visit
    end
  rescue StandardError => e
    warn "Warning: Payment request mock injection failed: #{e.message}"
  end

  def clear_payment_request_mocks
    if @cdp_script_identifier
      page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: @cdp_script_identifier)
    end
  rescue StandardError => e
    warn "Warning: Payment request mock cleanup failed: #{e.message}"
  ensure
    @cdp_script_identifier = nil
  end

  let(:product) { create(:product, price_cents: 2000, name: "Test Product") }

  after { clear_payment_request_mocks }

  context "Apple Pay" do
    before { inject_payment_request_mock(apple_pay: true) }

    it "allows choosing Apple Pay or card" do
      visit product.long_url
      add_to_cart(product)

      choose "Apple Pay"
      expect(page).to have_checked_field("Apple Pay")
      expect(page).not_to have_selector("fieldset[aria-label='Card information']")
      expect(page).to have_button("Pay")

      choose "Card"
      expect(page).to have_selector("fieldset[aria-label='Card information']")
    end

    it "returns to input state when payment is cancelled" do
      visit product.long_url
      add_to_cart(product)

      fill_in "Email address", with: "buyer@example.com"
      choose "Apple Pay"
      find_button("Pay").click

      expect(page).to have_button("Pay")
    end

    it "shows Pay button and email field when Apple Pay is selected" do
      visit product.long_url
      add_to_cart(product)

      choose "Apple Pay"

      expect(page).to have_field("Email address")
      expect(page).to have_button("Pay")
    end
  end

  context "Google Pay" do
    before { inject_payment_request_mock(google_pay: true) }

    it "allows choosing Google Pay or card" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"
      expect(page).to have_checked_field("Google Pay")
      expect(page).not_to have_selector("fieldset[aria-label='Card information']")
      expect(page).to have_button("Pay")

      choose "Card"
      expect(page).to have_selector("fieldset[aria-label='Card information']")
    end

    it "returns to input state when payment is cancelled" do
      visit product.long_url
      add_to_cart(product)

      fill_in "Email address", with: "buyer@example.com"
      choose "Google Pay"
      find_button("Pay").click

      expect(page).to have_button("Pay")
    end

    it "shows Pay button and email field when Google Pay is selected" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"

      expect(page).to have_field("Email address")
      expect(page).to have_button("Pay")
    end
  end

  context "both Apple Pay and Google Pay available" do
    before { inject_payment_request_mock(apple_pay: true, google_pay: true) }

    # When both are available, Stripe's payment request shows Google Pay label
    # (googlePay takes precedence in the component's isGooglePay check)
    it "shows payment request option and card" do
      visit product.long_url
      add_to_cart(product)

      expect(page).to have_field("Google Pay", type: "radio")
      expect(page).to have_field("Card", type: "radio")
    end

    it "can switch between payment request and card" do
      visit product.long_url
      add_to_cart(product)

      choose "Google Pay"
      expect(page).to have_checked_field("Google Pay")
      expect(page).not_to have_selector("fieldset[aria-label='Card information']")

      choose "Card"
      expect(page).to have_checked_field("Card")
      expect(page).to have_selector("fieldset[aria-label='Card information']")
    end
  end

  context "no payment request methods available" do
    before { inject_payment_request_mock }

    it "only shows credit card option" do
      visit product.long_url
      add_to_cart(product)

      expect(page).not_to have_field("Google Pay", type: "radio")
      expect(page).not_to have_field("Apple Pay", type: "radio")
      # When no payment request methods are available, card is shown without radio (single option)
      expect(page).not_to have_field("Card", type: "radio")
      expect(page).to have_selector("fieldset[aria-label='Card information']")
    end
  end
end
