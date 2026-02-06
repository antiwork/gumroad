# frozen_string_literal: true

require "spec_helper"

describe "Checkout with Apple Pay and Google Pay", :js, type: :system do
  before do
    @product = create(:product, price_cents: 1000)
  end

  # Helper to inject a script that mocks payment availability APIs before page load
  # This uses CDP (Chrome DevTools Protocol) to inject JavaScript that runs before any page scripts
  #
  # Stripe.js checks:
  # - For Apple Pay: window.ApplePaySession and ApplePaySession.canMakePayments()
  # - For Google Pay: PaymentRequest API with basic-card or google pay method
  #
  # We intercept Stripe's paymentRequest.canMakePayment() result by patching the Stripe constructor
  def mock_payment_methods(apple_pay: false, google_pay: false)
    script = <<~JS
      (function() {
        // Store mock configuration globally
        window.__paymentMock = { applePay: #{apple_pay.to_s}, googlePay: #{google_pay.to_s} };

        // Mock ApplePaySession for Apple Pay detection
        if (#{apple_pay.to_s}) {
          window.ApplePaySession = class MockApplePaySession {
            static supportsVersion(version) { return true; }
            static canMakePayments() { return true; }
            static canMakePaymentsWithActiveCard(merchantIdentifier) {
              return Promise.resolve(true);
            }
            constructor(version, request) {
              this.version = version;
              this.request = request;
            }
            begin() {}
            abort() {}
            completeMerchantValidation(session) {}
            completePayment(status) {}
            completePaymentMethodSelection(update) {}
            completeShippingContactSelection(update) {}
            completeShippingMethodSelection(update) {}
          };
        }

        // Intercept Stripe to patch paymentRequest
        const originalDescriptor = Object.getOwnPropertyDescriptor(window, 'Stripe');
        let stripeValue = null;

        Object.defineProperty(window, 'Stripe', {
          configurable: true,
          enumerable: true,
          get: function() {
            return stripeValue;
          },
          set: function(newStripe) {
            if (typeof newStripe === 'function') {
              // Wrap the Stripe constructor
              stripeValue = function(...args) {
                const instance = newStripe.apply(this, args);
                if (instance && instance.paymentRequest) {
                  const originalPaymentRequest = instance.paymentRequest.bind(instance);
                  instance.paymentRequest = function(options) {
                    const pr = originalPaymentRequest(options);
                    const originalCanMake = pr.canMakePayment.bind(pr);

                    pr.canMakePayment = function() {
                      // Return our mock result instead of checking real APIs
                      const mock = window.__paymentMock;
                      if (mock.applePay || mock.googlePay) {
                        return Promise.resolve({
                          applePay: mock.applePay,
                          googlePay: mock.googlePay
                        });
                      }
                      return Promise.resolve(null);
                    };

                    // Mock show() since we can't actually complete payment
                    const originalShow = pr.show.bind(pr);
                    pr.show = function() {
                      // Trigger cancel event to simulate user cancellation
                      setTimeout(() => {
                        if (pr._listeners && pr._listeners.cancel) {
                          pr._listeners.cancel.forEach(fn => fn());
                        }
                      }, 100);
                      return Promise.reject(new DOMException('The operation was aborted.', 'AbortError'));
                    };

                    // Store event listeners so we can trigger them
                    pr._listeners = {};
                    const originalOn = pr.on.bind(pr);
                    pr.on = function(event, handler) {
                      pr._listeners[event] = pr._listeners[event] || [];
                      pr._listeners[event].push(handler);
                      return originalOn(event, handler);
                    };

                    return pr;
                  };
                }
                return instance;
              };
              // Copy any static properties
              Object.keys(newStripe).forEach(key => {
                stripeValue[key] = newStripe[key];
              });
            } else {
              stripeValue = newStripe;
            }
          }
        });
      })();
    JS

    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: script)
  end

  describe "Apple Pay" do
    before do
      mock_payment_methods(apple_pay: true, google_pay: false)
    end

    it "shows Apple Pay option when available" do
      visit @product.long_url
      add_to_cart(@product)

      # Assert Apple Pay option is visible in payment methods
      expect(page).to have_text("Apple Pay")
      expect(page).to have_selector(".brand-icon-apple")
    end

    it "allows selecting Apple Pay as payment method" do
      visit @product.long_url
      add_to_cart(@product)

      # Select Apple Pay by clicking on the payment method option
      find("h4", text: "Apple Pay").ancestor("[role='radio']").click

      # Verify Apple Pay is selected (the radio should be checked)
      expect(find("h4", text: "Apple Pay").ancestor("[role='radio']")["aria-checked"]).to eq("true")

      # Verify the Pay button is visible
      expect(page).to have_button("Pay")
    end

    it "returns to input state when Apple Pay payment is cancelled" do
      visit @product.long_url
      add_to_cart(@product)

      # Fill in required email
      fill_in "Email address", with: "test@gumroad.com"

      # Select Apple Pay
      find("h4", text: "Apple Pay").ancestor("[role='radio']").click

      # Click Pay - the mock will trigger a cancellation
      click_on "Pay", exact: true

      # After cancellation, we should return to the checkout form
      # The form should still be visible and editable
      expect(page).to have_field("Email address", with: "test@gumroad.com")
      expect(page).to have_button("Pay")
    end
  end

  describe "Google Pay" do
    before do
      mock_payment_methods(apple_pay: false, google_pay: true)
    end

    it "shows Google Pay option when available" do
      visit @product.long_url
      add_to_cart(@product)

      # Assert Google Pay option is visible in payment methods
      expect(page).to have_text("Google Pay")
      expect(page).to have_selector(".brand-icon-google")
    end

    it "allows selecting Google Pay as payment method" do
      visit @product.long_url
      add_to_cart(@product)

      # Select Google Pay by clicking on the payment method option
      find("h4", text: "Google Pay").ancestor("[role='radio']").click

      # Verify Google Pay is selected
      expect(find("h4", text: "Google Pay").ancestor("[role='radio']")["aria-checked"]).to eq("true")

      # Verify the Pay button is visible
      expect(page).to have_button("Pay")
    end

    it "returns to input state when Google Pay payment is cancelled" do
      visit @product.long_url
      add_to_cart(@product)

      # Fill in required email
      fill_in "Email address", with: "test@gumroad.com"

      # Select Google Pay
      find("h4", text: "Google Pay").ancestor("[role='radio']").click

      # Click Pay - the mock will trigger a cancellation
      click_on "Pay", exact: true

      # After cancellation, we should return to the checkout form
      expect(page).to have_field("Email address", with: "test@gumroad.com")
      expect(page).to have_button("Pay")
    end
  end

  describe "when neither Apple Pay nor Google Pay is available" do
    before do
      mock_payment_methods(apple_pay: false, google_pay: false)
    end

    it "does not show Apple Pay or Google Pay options" do
      visit @product.long_url
      add_to_cart(@product)

      # Neither option should be visible
      expect(page).not_to have_text("Apple Pay")
      expect(page).not_to have_text("Google Pay")
      expect(page).not_to have_selector(".brand-icon-apple")
      expect(page).not_to have_selector(".brand-icon-google")
    end

    it "allows checkout with regular credit card" do
      visit @product.long_url
      add_to_cart(@product)

      # Regular credit card checkout should still work
      check_out(@product)
    end
  end

  describe "form fields visibility" do
    before do
      mock_payment_methods(apple_pay: true, google_pay: false)
    end

    it "hides credit card fields when Apple Pay is selected" do
      visit @product.long_url
      add_to_cart(@product)

      # Initially, card fields should be visible (card is default)
      expect(page).to have_fieldset("Card information")

      # Select Apple Pay
      find("h4", text: "Apple Pay").ancestor("[role='radio']").click

      # Card information fieldset should not be visible when Apple Pay is selected
      expect(page).not_to have_fieldset("Card information")
    end

    it "shows email field when Apple Pay is selected" do
      visit @product.long_url
      add_to_cart(@product)

      # Select Apple Pay
      find("h4", text: "Apple Pay").ancestor("[role='radio']").click

      # Email should still be visible (Apple Pay will provide it, but field is still shown)
      expect(page).to have_field("Email address")
    end

    it "shows the Pay button with Apple Pay selected" do
      visit @product.long_url
      add_to_cart(@product)

      # Select Apple Pay
      find("h4", text: "Apple Pay").ancestor("[role='radio']").click

      # Pay button should be visible and enabled
      expect(page).to have_button("Pay", disabled: false)
    end
  end

  describe "payment method switching" do
    before do
      mock_payment_methods(apple_pay: true, google_pay: false)
    end

    it "can switch between Apple Pay and credit card" do
      visit @product.long_url
      add_to_cart(@product)

      # Card should be default
      expect(page).to have_fieldset("Card information")

      # Switch to Apple Pay
      find("h4", text: "Apple Pay").ancestor("[role='radio']").click
      expect(page).not_to have_fieldset("Card information")

      # Switch back to Card
      find("h4", text: "Card").ancestor("[role='radio']").click
      expect(page).to have_fieldset("Card information")
    end
  end
end
