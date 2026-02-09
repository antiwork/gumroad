# frozen_string_literal: true

module PaymentRequestMockHelper
  def mock_payment_request(supports_apple_pay: false, supports_google_pay: false)
    # We use Page.addScriptToEvaluateOnNewDocument to ensure the mock is present
    # as soon as the page starts loading.

    script = <<~JS
      (function() {
        const originalPaymentRequest = window.PaymentRequest;

        class MockPaymentRequest {
          constructor(methodData, details, options) {
            this.methodData = methodData;
            this.details = details;
            this.options = options;
          }

          async canMakePayment() {
            const supportsApplePay = #{supports_apple_pay};
            const supportsGooglePay = #{supports_google_pay};

            const isApplePay = this.methodData.some(m => m.supportedMethods === 'https://apple.com/apple-pay');
            const isGooglePay = this.methodData.some(m => m.supportedMethods === 'https://google.com/pay' || m.supportedMethods === 'google_pay');

            if (isApplePay) return supportsApplePay;
            if (isGooglePay) return supportsGooglePay;

            return false;
          }

          async show() {
            console.log('MockPaymentRequest.show() called');
            return {
              complete: async (result) => console.log('MockPaymentRequest complete:', result),
              details: {
                paymentMethod: 'mock',
              }
            };
          }
        }

        window.PaymentRequest = MockPaymentRequest;

        // Also mock Stripe's paymentRequest if it's used
        // We'll hook into window.Stripe if it's loaded later
        let originalStripe = window.Stripe;
        Object.defineProperty(window, 'Stripe', {
          get: function() {
            return function(key, options) {
              const stripe = originalStripe ? originalStripe(key, options) : {
                // If the real Stripe isn't loaded yet, provide a mock
                elements: (options) => ({
                  create: (type, options) => ({
                    mount: (el) => {},
                    on: (event, handler) => {},
                    destroy: () => {}
                  }),
                  getElement: (type) => null
                }),
                createToken: async (element) => ({ token: { id: 'tok_test' } }),
                createSource: async (element) => ({ source: { id: 'src_test' } }),
                createPaymentMethod: async (element) => ({ paymentMethod: { id: 'pm_test' } }),
                confirmCardPayment: async (secret, elements) => ({ paymentIntent: { status: 'succeeded' } }),
                confirmCardSetup: async (secret, elements) => ({ setupIntent: { status: 'succeeded' } }),
                paymentRequest: function(params) {
                  return {
                    canMakePayment: async () => {
                      const supportsApplePay = #{supports_apple_pay};
                      const supportsGooglePay = #{supports_google_pay};
                      const result = {};
                      if (supportsApplePay) result.applePay = true;
                      if (supportsGooglePay) result.googlePay = true;
                      return Object.keys(result).length > 0 ? result : null;
                    },
                    on: () => {},
                    show: () => {}
                  };
                }
              };

              // If we have the real stripe instance, just patch paymentRequest
              if (originalStripe) {
                const originalPaymentRequest = stripe.paymentRequest;
                stripe.paymentRequest = function(params) {
                  return {
                    canMakePayment: async () => {
                      const supportsApplePay = #{supports_apple_pay};
                      const supportsGooglePay = #{supports_google_pay};
                      const result = {};
                      if (supportsApplePay) result.applePay = true;
                      if (supportsGooglePay) result.googlePay = true;
                      return Object.keys(result).length > 0 ? result : null;
                    },
                    on: () => {},
                    show: () => {}
                  };
                };
              }

              return stripe;
            };
          },
          set: function(val) {
            originalStripe = val;
          },
          configurable: true
        });
      })();
    JS

    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: script)

    # Also stub Routes in the frontend to use the current host
    routes_stub = <<~JS
      (function() {
        // Function to patch Routes
        function patchRoutes(routesObj) {
          if (!routesObj || routesObj._patched) return;

          const originalCheckoutIndexUrl = routesObj.checkout_index_url;
          if (originalCheckoutIndexUrl) {
            routesObj.checkout_index_url = function(options) {
              const url = new URL(originalCheckoutIndexUrl.call(routesObj, options));
              url.host = window.location.host;
              url.protocol = window.location.protocol;
              return url.toString();
            };
            routesObj._patched = true;
          }
        }

        // If Routes already exists, patch it
        if (typeof Routes !== 'undefined') {
          patchRoutes(Routes);
        }

        // Also hook into window.Routes definition for when it loads later
        let _Routes = window.Routes;
        Object.defineProperty(window, 'Routes', {
          get: function() { return _Routes; },
          set: function(val) {
            _Routes = val;
            patchRoutes(_Routes);
          },
          configurable: true
        });
      })();
    JS
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: routes_stub)
  end

  def print_browser_logs
    logs = page.driver.browser.logs.get(:browser)
    puts "\n--- BROWSER LOGS ---"
    logs.each do |log|
      puts "[#{log.level}] #{log.message}"
    end
    puts "--------------------\n"
  rescue => e
    puts "Could not get browser logs: #{e.message}"
  end
end
