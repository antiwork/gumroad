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
            this._listeners = {};
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

            if (window.__triggerShippingAddressChange) {
              setTimeout(() => {
                const event = {
                  type: 'shippingaddresschange',
                  shippingAddress: {
                    country: 'US',
                    region: 'CA',
                    city: 'San Francisco',
                    addressLine: ['123 Test St'],
                    postalCode: '94105',
                    recipient: 'Test User'
                  },
                  updateWith: (details) => {
                    console.log('MockPaymentRequest shippingaddresschange.updateWith called:', details);
                    return Promise.resolve(details);
                  }
                };
                this.dispatchEvent(event);
              }, 100);
            }

            if (window.__triggerPaymentCancel) {
              setTimeout(() => {
                const event = new Event('cancel');
                this.dispatchEvent(event);
                if (this._oncancel) this._oncancel(event);
              }, 100);
              return Promise.reject(new DOMException('The operation was aborted.', 'AbortError'));
            }

            if (window.__triggerPaymentSuccess) {
              setTimeout(() => {
                const event = {
                  type: 'paymentmethod',
                  paymentMethod: {
                    id: 'pm_mock_success',
                    card: { country: 'US', wallet: { type: 'apple_pay' } },
                    billing_details: {
                      email: 'test@gumroad.com',
                      address: { postal_code: '12345', country: 'US' }
                    }
                  },
                  payerName: 'Test User',
                  payerEmail: 'test@gumroad.com',
                  complete: async (result) => console.log('MockPaymentRequest complete:', result)
                };
                this.dispatchEvent(event);
              }, 100);
            }

            return {
              complete: async (result) => console.log('MockPaymentRequest complete:', result),
              details: { paymentMethod: 'mock' }
            };
          }

          addEventListener(type, listener) {
            this._listeners[type] = this._listeners[type] || [];
            this._listeners[type].push(listener);
          }

          dispatchEvent(event) {
            if (this._listeners[event.type]) {
              this._listeners[event.type].forEach(l => l(event));
            }
          }

          set oncancel(fn) { this._oncancel = fn; }
        }

        window.PaymentRequest = MockPaymentRequest;

        function createStripePaymentRequestMock() {
          const pr = {
            _listeners: {},
            canMakePayment: async () => {
              const supportsApplePay = #{supports_apple_pay};
              const supportsGooglePay = #{supports_google_pay};
              const result = {};
              if (supportsApplePay) result.applePay = true;
              if (supportsGooglePay) result.googlePay = true;
              return Object.keys(result).length > 0 ? result : null;
            },
            update: (options) => {
              console.log('StripeMock.paymentRequest.update called:', options);
            },
            on: (event, handler) => {
              pr._listeners[event] = pr._listeners[event] || [];
              pr._listeners[event].push(handler);
            },
            show: () => {
              console.log('StripeMock.paymentRequest.show() called');

              if (window.__triggerShippingAddressChange) {
                setTimeout(() => {
                  if (pr._listeners.shippingaddresschange) {
                    const event = {
                      shippingAddress: {
                        country: 'US',
                        region: 'CA',
                        city: 'San Francisco',
                        addressLine: ['123 Test St'],
                        postalCode: '94105',
                        recipient: 'Test User'
                      },
                      updateWith: (details) => {
                        console.log('StripeMock shippingaddresschange.updateWith called:', details);
                        return Promise.resolve(details);
                      }
                    };
                    pr._listeners.shippingaddresschange.forEach(fn => fn(event));
                  }
                }, 100);
              }

              if (window.__triggerPaymentCancel) {
                setTimeout(() => {
                  if (pr._listeners.cancel) pr._listeners.cancel.forEach(fn => fn());
                }, 100);
              } else if (window.__triggerPaymentSuccess) {
                setTimeout(() => {
                  if (pr._listeners.paymentmethod) {
                    const event = {
                      paymentMethod: {
                        id: 'pm_mock_success',
                        card: { country: 'US', wallet: { type: 'google_pay' } },
                        billing_details: {
                          email: 'test@gumroad.com',
                          name: 'Test User',
                          address: { postal_code: '12345', country: 'US' }
                        }
                      },
                      payerName: 'Test User',
                      payerEmail: 'test@gumroad.com',
                      complete: (result) => console.log('StripeMock complete:', result)
                    };
                    pr._listeners.paymentmethod.forEach(fn => fn(event));
                  }
                }, 100);
              }
            }
          };
          return pr;
        }

        let originalStripe = window.Stripe;
        Object.defineProperty(window, 'Stripe', {
          get: function() {
            return function(key, options) {
              const mockStripe = {
                elements: (options) => ({
                  create: (type, options) => ({
                    mount: (el) => {},
                    unmount: () => {},
                    on: (event, handler) => {},
                    off: (event, handler) => {},
                    update: (options) => {},
                    destroy: () => {},
                    focus: () => {},
                    blur: () => {},
                    clear: () => {}
                  }),
                  getElement: (type) => null
                }),
                createToken: async (element) => ({ token: { id: 'tok_test' } }),
                createSource: async (element, options) => ({ source: { id: 'src_test' } }),
                createPaymentMethod: async (data) => ({ paymentMethod: { id: 'pm_test' } }),
                confirmCardPayment: async (secret, elements) => ({ paymentIntent: { status: 'succeeded' } }),
                confirmCardSetup: async (secret, elements) => ({ setupIntent: { status: 'succeeded' } }),
                paymentRequest: createStripePaymentRequestMock
              };

              // If real Stripe loaded, use it but override paymentRequest
              const stripe = originalStripe ? originalStripe(key, options) : mockStripe;

              if (originalStripe) {
                stripe.paymentRequest = createStripePaymentRequestMock;
              }
              return stripe;
            };
          },
          set: function(val) { originalStripe = val; },
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
