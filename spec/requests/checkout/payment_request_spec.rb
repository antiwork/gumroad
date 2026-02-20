# frozen_string_literal: true

require "spec_helper"

describe "Checkout with Payment Request API", :js, type: :system do
  def mock_payment_request_availability(apple_pay: false, google_pay: false)
    @payment_request_mock_script = <<~JS
      (function() {
        window.__mockStripe = function(OriginalStripe) {
          return function(...args) {
            const stripe = OriginalStripe.apply(this, args);
            if (!stripe) return null;

            const originalPaymentRequest = stripe.paymentRequest.bind(stripe);

            stripe.paymentRequest = function(options) {
              const pr = originalPaymentRequest(options);
              const originalCanMakePayment = pr.canMakePayment.bind(pr);
              const originalShow = pr.show.bind(pr);

              pr.canMakePayment = function() {
                return Promise.resolve({
                  applePay: #{apple_pay},
                  googlePay: #{google_pay}
                });
              };

              pr.show = function() {
                return originalShow().catch((error) => {
                  if (error.message.includes('not supported') || error.message.includes('Not available')) {
                    setTimeout(() => {
                      const cancelEvent = new Event('cancel');
                      if (pr.emit) pr.emit('cancel', cancelEvent);
                    }, 100);
                  }
                  throw error;
                });
              };

              return pr;
            };

            return stripe;
          };
        };

        if (window.Stripe) {
          const OriginalStripe = window.Stripe;
          window.Stripe = window.__mockStripe(OriginalStripe);
          Object.setPrototypeOf(window.Stripe, OriginalStripe);
          Object.keys(OriginalStripe).forEach(key => {
            window.Stripe[key] = OriginalStripe[key];
          });
        }

        #{apple_pay ? mock_apple_pay_session : ''}
      })();
    JS
  end

  def inject_payment_request_mock
    return unless @payment_request_mock_script

    page.execute_script(@payment_request_mock_script)
  rescue StandardError => e
    warn "Warning: Payment request mock injection failed: #{e.message}"
  end

  def mock_apple_pay_session
    <<~JS
      if (!window.ApplePaySession) {
        window.ApplePaySession = {
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
      }
    JS
  end

  def clear_payment_request_mocks
    page.driver.browser.execute_cdp(
      'Page.addScriptToEvaluateOnNewDocument',
      source: 'delete window.__payment_request_mocked;'
    )
  rescue StandardError
  end

  let(:product) { create(:product, price_cents: 2000, name: "Test Product") }

  after do
    clear_payment_request_mocks
  end

  context "Apple Pay" do
    before do
      mock_payment_request_availability(apple_pay: true, google_pay: false)
    end

    it "allows selecting Apple Pay" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      expect(page).to have_field("Apple Pay", type: "radio", wait: 10)

      within_fieldset("Payment method") do
        expect(page).to have_text("Apple Pay")

        apple_pay_label = find("label", text: "Apple Pay")
        expect(apple_pay_label).to have_selector("svg, img, [class*='apple'], [class*='ApplePay']")
      end

      choose "Apple Pay"

      expect(page).to have_checked_field("Apple Pay", wait: 5)
      expect(page).not_to have_field("Card number")
      expect(page).not_to have_field("MM / YY")
      expect(page).not_to have_field("CVC")
      expect(page).to have_button("Pay", wait: 5)
    end

    it "can switch between Apple Pay and credit card" do
      visit product.long_url
      add_to_cart(product)

      choose "Apple Pay"

      expect(page).not_to have_field("Card number")
      expect(page).not_to have_field("MM / YY")
      expect(page).not_to have_field("CVC")

      choose "Credit card"

      expect(page).to have_field("Card number", wait: 5)
      expect(page).to have_field("MM / YY")
      expect(page).to have_field("CVC")
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

    it "requires email before allowing payment" do
      visit product.long_url
      add_to_cart(product)

      choose "Apple Pay"

      expect(page).to have_button("Pay", disabled: true, wait: 5)
      expect(page).to have_field("Email address")

      fill_in "Email address", with: "buyer@example.com"

      expect(page).to have_button("Pay", disabled: false, wait: 5)
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
      subscription_product = create(:product, :membership, price_cents: 1500, subscription_duration: "monthly")

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
    end

    it "allows selecting Google Pay" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)

      within_fieldset("Payment method") do
        expect(page).to have_text("Google Pay")

        google_pay_label = find("label", text: "Google Pay")
        expect(google_pay_label).to have_selector("svg, img, [class*='google'], [class*='GooglePay']")
      end

      choose "Google Pay"

      expect(page).to have_checked_field("Google Pay", wait: 5)
      expect(page).not_to have_field("Card number")
      expect(page).not_to have_field("MM / YY")
      expect(page).not_to have_field("CVC")
      expect(page).to have_button("Pay", wait: 5)
    end

    it "can switch between Google Pay and credit card" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      choose "Google Pay"

      expect(page).not_to have_field("Card number")
      expect(page).not_to have_field("MM / YY")
      expect(page).not_to have_field("CVC")

      choose "Credit card"

      expect(page).to have_field("Card number", wait: 5)
      expect(page).to have_field("MM / YY")
      expect(page).to have_field("CVC")
    end

    it "returns to input state when payment is cancelled" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      fill_in "Email address", with: "buyer@example.com"
      choose "Google Pay"

      expect(page).to have_button("Pay", disabled: false)

      find_button("Pay").click

      expect(page).to have_button("Pay", wait: 10)
    end

    it "requires email before allowing payment" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      choose "Google Pay"

      expect(page).to have_button("Pay", disabled: true, wait: 5)
      expect(page).to have_field("Email address")

      fill_in "Email address", with: "buyer@example.com"

      expect(page).to have_button("Pay", disabled: false, wait: 5)
    end

    it "works with physical products" do
      physical_product = create(:product, :physical, price_cents: 3000)

      visit physical_product.long_url
      inject_payment_request_mock
      add_to_cart(physical_product)
      inject_payment_request_mock

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)

      choose "Google Pay"

      expect(page).to have_button("Pay", wait: 5)
    end

    it "works with subscriptions" do
      subscription_product = create(:product, :membership, price_cents: 1500, subscription_duration: "monthly")

      visit subscription_product.long_url
      inject_payment_request_mock
      add_to_cart(subscription_product)
      inject_payment_request_mock

      expect(page).to have_field("Google Pay", type: "radio", wait: 10)

      choose "Google Pay"

      expect(page).to have_button(text: /Pay|Subscribe/, wait: 5)
    end
  end

  context "both Apple Pay and Google Pay available" do
    before do
      mock_payment_request_availability(apple_pay: true, google_pay: true)
    end

    it "shows both payment options" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      expect(page).to have_field("Apple Pay", type: "radio", wait: 10)
      expect(page).to have_field("Google Pay", type: "radio")
      expect(page).to have_field("Credit card", type: "radio")
    end

    it "can switch between all payment methods" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      choose "Apple Pay"
      expect(page).to have_checked_field("Apple Pay")
      expect(page).not_to have_field("Card number")

      choose "Google Pay"
      expect(page).to have_checked_field("Google Pay")
      expect(page).not_to have_field("Card number")

      choose "Credit card"
      expect(page).to have_checked_field("Credit card")
      expect(page).to have_field("Card number", wait: 5)
    end
  end

  context "no payment request methods available" do
    before do
      mock_payment_request_availability(apple_pay: false, google_pay: false)
    end

    it "only shows credit card option" do
      visit product.long_url
      inject_payment_request_mock
      add_to_cart(product)
      inject_payment_request_mock

      expect(page).not_to have_field("Apple Pay", type: "radio")
      expect(page).not_to have_field("Google Pay", type: "radio")
      expect(page).to have_field("Credit card", type: "radio", wait: 10)
      expect(page).to have_checked_field("Credit card", wait: 10)
      expect(page).to have_field("Card number")
      expect(page).to have_field("MM / YY")
      expect(page).to have_field("CVC")
    end
  end
end
