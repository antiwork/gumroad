# frozen_string_literal: true

module PaymentRequestHelper
  def mock_payment_request_availability(apple_pay: false, google_pay: false)
    bridge = page.driver.browser.send(:bridge)

    mock_script = <<~JS
      (function() {
        const OriginalStripe = window.Stripe;

        window.Stripe = function(...args) {
          const stripe = OriginalStripe.apply(this, args);
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
                    pr.emit('cancel', cancelEvent);
                  }, 100);
                }
                throw error;
              });
            };

            return pr;
          };

          return stripe;
        };

        Object.setPrototypeOf(window.Stripe, OriginalStripe);
        Object.keys(OriginalStripe).forEach(key => {
          window.Stripe[key] = OriginalStripe[key];
        });

        #{apple_pay ? mock_apple_pay_session : ''}
      })();
    JS

    bridge.http.call(:post, "/session/#{bridge.session_id}/goog/cdp/execute", {
      cmd: 'Page.addScriptToEvaluateOnNewDocument',
      params: { source: mock_script }
    })
  rescue StandardError => e
    warn "Warning: CDP mocking unavailable: #{e.message}"
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
    bridge = page.driver.browser.send(:bridge)

    page.execute_script("window.location.href = 'about:blank'")
  rescue StandardError => e
    warn "Warning: Could not clear CDP mocks: #{e.message}"
  end
end

RSpec.configure do |config|
  config.include PaymentRequestHelper, type: :system
end
