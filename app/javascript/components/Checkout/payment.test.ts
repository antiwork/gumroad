import { describe, expect, it, vi } from "vitest";

import {
  canUseStripePaymentElement,
  canUseStripePaymentElementClientConfirm,
  computeTip,
  computeTipsForLines,
  getChargeTodayPrice,
  getFutureInstallmentsTotal,
  getStripePaymentElementAmount,
  getStripePaymentElementMountCurrency,
  getStripePaymentElementPresentment,
  isCardReadyToPay,
  reduceCheckoutState,
  requiresPaymentElementReusablePaymentMethod,
  requiresReusablePaymentMethodForCardCollection,
  requiresReusablePaymentMethod,
  STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT,
  type CheckoutPaymentConfig,
  type Product,
  type State,
} from "$app/components/Checkout/payment";

const stripePaymentElementMinimumCharge = 50;

const paymentElementConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: false,
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
    currency: "usd",
    buyer_currency_presentment: false,
    payment_method_types: ["card"],
    payment_method_creation: "manual",
  },
};

const buyerCurrencyPresentmentPaymentElementConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  disable_wallets: true,
  request_apple_pay_merchant_tokens: false,
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
    currency: "usd",
    buyer_currency_presentment: true,
    payment_method_types: ["card"],
    payment_method_creation: "manual",
    stripe_link_enabled: true,
  },
};

const futureChargePaymentElementConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: false,
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT,
    currency: "usd",
    buyer_currency_presentment: false,
    payment_method_types: ["card"],
    payment_method_creation: "manual",
    stripe_link_enabled: false,
  },
};

const cardElementConfig: CheckoutPaymentConfig = {
  integration: "card_element",
  fallback_reason: "stripe_payment_element_flag_disabled",
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: false,
  elements_options: null,
};

const paymentElementClientConfirmConfig: CheckoutPaymentConfig = {
  integration: "payment_element_client_confirm",
  fallback_reason: null,
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: false,
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
    currency: "usd",
    presentment_amount_cents: null,
    payment_method_types: ["card"],
    stripe_link_enabled: false,
    stripe_connect_account_id: null,
  },
};

const product = (overrides: Partial<Product> = {}): Product => ({
  permalink: "product-a",
  name: "Product A",
  creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" },
  quantity: 1,
  price: 1_000,
  payInInstallments: false,
  requireShipping: false,
  customFields: [],
  bundleProductCustomFields: [],
  supportsPaypal: null,
  testPurchase: false,
  requirePayment: true,
  hasFreeTrial: false,
  hasTippingEnabled: false,
  isPreorder: false,
  canGift: false,
  nativeType: "digital",
  recurrence: null,
  shippableCountryCodes: [],
  ...overrides,
});

const state = (overrides: Partial<State> = {}): State => ({
  products: [product()],
  countries: { US: "United States" },
  usStates: [],
  caProvinces: [],
  tipOptions: [],
  country: "US",
  email: "buyer@example.com",
  vatId: "",
  fullName: "Buyer",
  address: "",
  city: "",
  state: "",
  zipCode: "10001",
  saveAddress: false,
  gift: null,
  customFieldValues: {},
  surcharges: {
    type: "loaded",
    result: {
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 0,
      tax_included_cents: 0,
      subtotal: 1_000,
      buyer_currency_quote: null,
    },
  },
  availablePaymentMethods: [],
  paymentMethod: "card",
  willSaveCard: false,
  savedCreditCard: null,
  checkoutPayment: paymentElementConfig,
  status: { type: "input", errors: new Set() },
  recaptchaKey: null,
  paypalClientId: "",
  tip: { type: "percentage", percentage: 0 },
  emailTypoSuggestion: null,
  acknowledgedEmails: new Set(),
  requireEmailTypoAcknowledgment: false,
  ...overrides,
});

describe("canUseStripePaymentElement", () => {
  it("allows a flagged positive one-off card checkout without a saved card", () => {
    expect(canUseStripePaymentElement(state())).toBe(true);
  });

  it("falls back when the server selected the Card Element integration", () => {
    expect(canUseStripePaymentElement(state({ checkoutPayment: cardElementConfig }))).toBe(false);
  });

  it("falls back when the cart is empty", () => {
    expect(canUseStripePaymentElement(state({ products: [] }))).toBe(false);
  });

  it("allows a checkout when a saved card is available (the saved-card toggle handles it)", () => {
    expect(
      canUseStripePaymentElement(
        state({
          savedCreditCard: { type: "visa", number: "**** 4242", expiration_date: "12/30", requires_mandate: false },
        }),
      ),
    ).toBe(true);
  });

  it("allows multi-seller carts", () => {
    expect(
      canUseStripePaymentElement(
        state({
          products: [
            product({ creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" } }),
            product({ creator: { id: "seller-b", name: "Seller B", profile_url: "", avatar_url: "" } }),
          ],
        }),
      ),
    ).toBe(true);
  });

  it("collects a reusable card for multi-seller Payment Element carts", () => {
    const multiSeller = state({
      products: [
        product({ creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" } }),
        product({ creator: { id: "seller-b", name: "Seller B", profile_url: "", avatar_url: "" } }),
      ],
    });
    expect(requiresReusablePaymentMethodForCardCollection(multiSeller, true)).toBe(true);
  });

  it("allows reusable card flows that keep the stripe payment method contract", () => {
    expect(canUseStripePaymentElement(state({ products: [product({ subscription_id: "sub_123" })] }))).toBe(true);
    expect(canUseStripePaymentElement(state({ products: [product({ recurrence: "monthly" })] }))).toBe(true);
    expect(canUseStripePaymentElement(state({ products: [product({ nativeType: "commission" })] }))).toBe(true);
  });

  it("falls back for future-charge and installment flows in PaymentIntent mode", () => {
    expect(canUseStripePaymentElement(state({ products: [product({ payInInstallments: true })] }))).toBe(false);
    expect(canUseStripePaymentElement(state({ products: [product({ isPreorder: true })] }))).toBe(false);
    expect(canUseStripePaymentElement(state({ products: [product({ hasFreeTrial: true })] }))).toBe(false);
  });

  it("allows setup-mode checkout for preorder and free-trial flows", () => {
    expect(
      canUseStripePaymentElement(
        state({ checkoutPayment: futureChargePaymentElementConfig, products: [product({ isPreorder: true })] }),
      ),
    ).toBe(true);
    expect(
      canUseStripePaymentElement(
        state({ checkoutPayment: futureChargePaymentElementConfig, products: [product({ hasFreeTrial: true })] }),
      ),
    ).toBe(true);
  });

  it("falls back for setup-mode checkout when mixed with a charged product", () => {
    expect(
      canUseStripePaymentElement(
        state({
          checkoutPayment: futureChargePaymentElementConfig,
          products: [product({ isPreorder: true }), product({ permalink: "charged-product" })],
        }),
      ),
    ).toBe(false);
  });

  it("allows SetupIntent mode when every product is charged in the future", () => {
    expect(
      canUseStripePaymentElement(
        state({ checkoutPayment: futureChargePaymentElementConfig, products: [product({ isPreorder: true })] }),
      ),
    ).toBe(true);
    expect(
      canUseStripePaymentElement(
        state({ checkoutPayment: futureChargePaymentElementConfig, products: [product({ hasFreeTrial: true })] }),
      ),
    ).toBe(true);
    expect(
      canUseStripePaymentElement(
        state({
          checkoutPayment: futureChargePaymentElementConfig,
          products: [
            product({ isPreorder: true }),
            product({ permalink: "membership", hasFreeTrial: true, recurrence: "monthly" }),
          ],
        }),
      ),
    ).toBe(true);
  });

  it("falls back in SetupIntent mode when future-charge products are mixed with charged products", () => {
    expect(
      canUseStripePaymentElement(
        state({
          checkoutPayment: futureChargePaymentElementConfig,
          products: [product({ isPreorder: true }), product({ permalink: "product-b" })],
        }),
      ),
    ).toBe(false);
  });

  it("falls back in SetupIntent mode for non-future-charge, installment, and zero-amount products", () => {
    expect(
      canUseStripePaymentElement(
        state({
          checkoutPayment: futureChargePaymentElementConfig,
          products: [product({ nativeType: "commission" })],
        }),
      ),
    ).toBe(false);
    expect(
      canUseStripePaymentElement(
        state({ checkoutPayment: futureChargePaymentElementConfig, products: [product({ payInInstallments: true })] }),
      ),
    ).toBe(false);
    expect(
      canUseStripePaymentElement(
        state({
          checkoutPayment: futureChargePaymentElementConfig,
          products: [product({ isPreorder: true, price: 0 })],
        }),
      ),
    ).toBe(false);
  });

  it("falls back when loaded checkout total is zero", () => {
    expect(
      canUseStripePaymentElement(
        state({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 0,
              tax_cents: 0,
              tax_included_cents: 0,
              subtotal: 0,
              buyer_currency_quote: null,
            },
          },
        }),
      ),
    ).toBe(false);
  });

  it("falls back when loaded checkout total is below Stripe's USD minimum charge amount", () => {
    expect(
      canUseStripePaymentElement(
        state({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 0,
              tax_cents: 0,
              tax_included_cents: 0,
              subtotal: 49,
              buyer_currency_quote: null,
            },
          },
        }),
      ),
    ).toBe(false);
  });

  it("keeps the Payment Element path selected while the final total is pending", () => {
    expect(canUseStripePaymentElement(state({ surcharges: { type: "pending" } }))).toBe(true);
  });

  it("allows a loaded checkout total below Gumroad's USD minimum when Stripe can charge it", () => {
    expect(
      canUseStripePaymentElement(
        state({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 0,
              tax_cents: 0,
              tax_included_cents: 0,
              subtotal: 98,
              buyer_currency_quote: null,
            },
          },
        }),
      ),
    ).toBe(true);
  });
});

describe("canUseStripePaymentElementClientConfirm", () => {
  const clientConfirmState = (overrides: Partial<State> = {}) =>
    state({ checkoutPayment: paymentElementClientConfirmConfig, ...overrides });

  it("allows a single-seller one-off card checkout when the server selected the confirm integration", () => {
    expect(canUseStripePaymentElementClientConfirm(clientConfirmState())).toBe(true);
  });

  it("falls back when the server selected the server-confirm Payment Element integration", () => {
    expect(canUseStripePaymentElementClientConfirm(state())).toBe(false);
  });

  it("falls back when the server selected the Card Element integration", () => {
    expect(canUseStripePaymentElementClientConfirm(state({ checkoutPayment: cardElementConfig }))).toBe(false);
  });

  it("falls back when the cart is empty", () => {
    expect(canUseStripePaymentElementClientConfirm(clientConfirmState({ products: [] }))).toBe(false);
  });

  it("falls back for multi-seller carts because one ConfirmationToken funds one PaymentIntent", () => {
    expect(
      canUseStripePaymentElementClientConfirm(
        clientConfirmState({
          products: [
            product({ creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" } }),
            product({ creator: { id: "seller-b", name: "Seller B", profile_url: "", avatar_url: "" } }),
          ],
        }),
      ),
    ).toBe(false);
  });

  it("falls back for reusable-payment-method flows because client-confirm mode is one-time only", () => {
    expect(
      canUseStripePaymentElementClientConfirm(clientConfirmState({ products: [product({ recurrence: "monthly" })] })),
    ).toBe(false);
    expect(
      canUseStripePaymentElementClientConfirm(
        clientConfirmState({ products: [product({ subscription_id: "sub_123" })] }),
      ),
    ).toBe(false);
    expect(
      canUseStripePaymentElementClientConfirm(
        clientConfirmState({ products: [product({ nativeType: "commission" })] }),
      ),
    ).toBe(false);
  });

  it("falls back for future-charge and installment flows", () => {
    expect(
      canUseStripePaymentElementClientConfirm(clientConfirmState({ products: [product({ payInInstallments: true })] })),
    ).toBe(false);
    expect(
      canUseStripePaymentElementClientConfirm(clientConfirmState({ products: [product({ isPreorder: true })] })),
    ).toBe(false);
    expect(
      canUseStripePaymentElementClientConfirm(clientConfirmState({ products: [product({ hasFreeTrial: true })] })),
    ).toBe(false);
  });

  it("keeps the confirm path selected while the final total is pending", () => {
    expect(canUseStripePaymentElementClientConfirm(clientConfirmState({ surcharges: { type: "pending" } }))).toBe(true);
  });

  it("falls back when the loaded checkout total is below Stripe's USD minimum charge amount", () => {
    expect(
      canUseStripePaymentElementClientConfirm(
        clientConfirmState({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 0,
              tax_cents: 0,
              tax_included_cents: 0,
              subtotal: stripePaymentElementMinimumCharge - 1,
            },
          },
        }),
      ),
    ).toBe(false);
  });
});

describe("requiresReusablePaymentMethod", () => {
  it("keeps the existing reusable setup contract for non-Payment Element paths", () => {
    expect(requiresReusablePaymentMethod(state())).toBe(false);
    expect(requiresReusablePaymentMethod(state({ products: [product({ subscription_id: "sub_123" })] }))).toBe(true);
    expect(requiresReusablePaymentMethod(state({ products: [product({ recurrence: "monthly" })] }))).toBe(false);
    expect(requiresReusablePaymentMethod(state({ products: [product({ nativeType: "commission" })] }))).toBe(true);
  });
});

describe("requiresPaymentElementReusablePaymentMethod", () => {
  it("requires reusable setup for Payment Element future-charge card flows", () => {
    expect(requiresPaymentElementReusablePaymentMethod(state())).toBe(false);
    expect(
      requiresPaymentElementReusablePaymentMethod(state({ products: [product({ subscription_id: "sub_123" })] })),
    ).toBe(true);
    expect(requiresPaymentElementReusablePaymentMethod(state({ products: [product({ recurrence: "monthly" })] }))).toBe(
      true,
    );
    expect(
      requiresPaymentElementReusablePaymentMethod(state({ products: [product({ nativeType: "commission" })] })),
    ).toBe(true);
    expect(
      requiresPaymentElementReusablePaymentMethod(
        state({ products: [product(), product({ permalink: "membership", recurrence: "monthly" })] }),
      ),
    ).toBe(true);
    expect(
      requiresPaymentElementReusablePaymentMethod(
        state({ products: [product(), product({ permalink: "subscription", subscription_id: "sub_123" })] }),
      ),
    ).toBe(true);
    expect(
      requiresPaymentElementReusablePaymentMethod(
        state({ products: [product(), product({ permalink: "commission", nativeType: "commission" })] }),
      ),
    ).toBe(true);
  });
});

describe("requiresReusablePaymentMethodForCardCollection", () => {
  it("routes recurring products through reusable setup for Payment Element card collection", () => {
    const recurringState = state({ products: [product({ recurrence: "monthly" })] });

    expect(requiresReusablePaymentMethodForCardCollection(recurringState, true)).toBe(true);
    expect(requiresReusablePaymentMethodForCardCollection(recurringState, false)).toBe(false);
  });

  it("does not create a reusable card before setup-mode Payment Element collection", () => {
    const setupState = state({
      checkoutPayment: futureChargePaymentElementConfig,
      products: [product({ hasFreeTrial: true, recurrence: "monthly" })],
    });

    expect(requiresReusablePaymentMethodForCardCollection(setupState, true)).toBe(false);
  });
});

describe("getStripePaymentElementAmount", () => {
  it("returns the loaded checkout total for eligible Payment Element checkouts", () => {
    expect(
      getStripePaymentElementAmount(
        state({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 200,
              tax_cents: 100,
              tax_included_cents: 0,
              subtotal: 1_000,
              buyer_currency_quote: null,
            },
          },
        }),
      ),
    ).toBe(1_300);
  });

  it("returns the loaded checkout total for the client-confirm integration", () => {
    expect(
      getStripePaymentElementAmount(
        state({
          checkoutPayment: paymentElementClientConfirmConfig,
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 200,
              tax_cents: 100,
              tax_included_cents: 0,
              subtotal: 1_000,
            },
          },
        }),
      ),
    ).toBe(1_300);
  });

  it("returns null until surcharges load", () => {
    expect(getStripePaymentElementAmount(state({ surcharges: { type: "pending" } }))).toBeNull();
  });

  it("returns null for setup-mode checkout", () => {
    expect(
      getStripePaymentElementAmount(
        state({ checkoutPayment: futureChargePaymentElementConfig, products: [product({ isPreorder: true })] }),
      ),
    ).toBeNull();
  });

  it("returns null when the loaded checkout total is zero", () => {
    expect(
      getStripePaymentElementAmount(
        state({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 0,
              tax_cents: 0,
              tax_included_cents: 0,
              subtotal: 0,
              buyer_currency_quote: null,
            },
          },
        }),
      ),
    ).toBeNull();
  });

  it("returns null when the loaded checkout total is below Stripe's USD minimum charge amount", () => {
    expect(
      getStripePaymentElementAmount(
        state({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 0,
              tax_cents: 0,
              tax_included_cents: 0,
              subtotal: stripePaymentElementMinimumCharge - 1,
              buyer_currency_quote: null,
            },
          },
        }),
      ),
    ).toBeNull();
  });

  it("returns a positive loaded total below Gumroad's USD minimum when the server selected Payment Element", () => {
    expect(
      getStripePaymentElementAmount(
        state({
          surcharges: {
            type: "loaded",
            result: {
              vat_id_valid: false,
              has_vat_id_input: false,
              shipping_rate_cents: 0,
              tax_cents: 0,
              tax_included_cents: 0,
              subtotal: 98,
              buyer_currency_quote: null,
            },
          },
        }),
      ),
    ).toBe(98);
  });
});

describe("buyer-currency presentment lane", () => {
  const buyerCurrencyQuote = {
    token: "quote-token",
    currency: "cad" as const,
    canonical_total_cents: 1_300,
    presentment_total_cents: 1_625,
    rate: 1.25,
    subunit_to_unit: 100,
    expires_at: "2026-07-10T00:00:00Z",
    line_allocations: [
      {
        permalink: "product-a",
        price_cents: 1_625,
        tip_cents: 0,
        tax_cents: 0,
        shipping_cents: 0,
        total_cents: 1_625,
      },
    ],
  };
  const loadedSurchargesWithQuote = {
    type: "loaded" as const,
    result: {
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 200,
      tax_cents: 100,
      tax_included_cents: 0,
      subtotal: 1_000,
      buyer_currency_quote: buyerCurrencyQuote,
    },
  };

  it("mounts the element with the quote's currency and locked local-currency total", () => {
    const s = state({
      checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
      surcharges: loadedSurchargesWithQuote,
    });
    expect(getStripePaymentElementPresentment(s)).toEqual({ currency: "cad", amountCents: 1_625 });
    expect(getStripePaymentElementAmount(s)).toBe(1_625);
  });

  it("mounts canonical USD when the surcharge response has no quote", () => {
    const s = state({
      checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
      surcharges: {
        type: "loaded",
        result: { ...loadedSurchargesWithQuote.result, buyer_currency_quote: null },
      },
    });
    expect(getStripePaymentElementPresentment(s)).toBeNull();
    expect(getStripePaymentElementAmount(s)).toBe(1_300);
  });

  it("mounts canonical USD when the quote allocation does not match the cart", () => {
    const s = state({
      checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
      surcharges: {
        type: "loaded",
        result: {
          ...loadedSurchargesWithQuote.result,
          buyer_currency_quote: {
            ...buyerCurrencyQuote,
            line_allocations: buyerCurrencyQuote.line_allocations.map((allocation) => ({
              ...allocation,
              permalink: "other",
            })),
          },
        },
      },
    });

    expect(getStripePaymentElementPresentment(s)).toBeNull();
    expect(getStripePaymentElementAmount(s)).toBe(1_300);
    expect(getStripePaymentElementMountCurrency(s)).toBe("usd");
  });

  it("mounts canonical USD when the buyer opts to save the card (canonical charge path)", () => {
    const s = state({
      checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
      surcharges: loadedSurchargesWithQuote,
      willSaveCard: true,
    });
    expect(getStripePaymentElementPresentment(s)).toBeNull();
    expect(getStripePaymentElementAmount(s)).toBe(1_300);
  });

  it("mounts canonical USD while a non-card payment method is selected", () => {
    // PayPal charges canonical USD (its merchant account can never pass presentment
    // eligibility), so the quote must be suppressed with the display: the buyer sees and
    // confirms the USD totals PayPal will charge, and no quote token is sent that the
    // charge path would fail closed on.
    const s = state({
      checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
      surcharges: loadedSurchargesWithQuote,
      paymentMethod: "paypal",
    });
    expect(getStripePaymentElementPresentment(s)).toBeNull();
    expect(getStripePaymentElementAmount(s)).toBe(1_300);
    expect(getStripePaymentElementMountCurrency(s)).toBe("usd");
  });

  it("ignores the quote when the server did not choose the presentment lane", () => {
    const s = state({ surcharges: loadedSurchargesWithQuote });
    expect(getStripePaymentElementPresentment(s)).toBeNull();
    expect(getStripePaymentElementAmount(s)).toBe(1_300);
  });

  it("returns null until surcharges load", () => {
    expect(
      getStripePaymentElementPresentment(
        state({ checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig, surcharges: { type: "pending" } }),
      ),
    ).toBeNull();
  });

  describe("getStripePaymentElementMountCurrency", () => {
    it("mounts in the quote's currency when the surcharge response carries one", () => {
      const s = state({
        checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
        surcharges: loadedSurchargesWithQuote,
      });
      expect(getStripePaymentElementMountCurrency(s)).toBe("cad");
    });

    it("reports the currency as unknowable while a surcharge refresh is in flight, so the element keeps its mount", () => {
      // Tip/address/VAT/cart edits move surcharges through pending and loading before the
      // refreshed quote lands. Reporting canonical USD in that window would remount the
      // element twice (CAD → USD → CAD), wiping the buyer's entered card details.
      for (const surcharges of [
        { type: "pending" as const },
        { type: "loading" as const, requestId: 1, abort: () => {} },
      ]) {
        const s = state({ checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig, surcharges });
        expect(getStripePaymentElementMountCurrency(s)).toBeNull();
      }
    });

    it("mounts canonical USD when a loaded surcharge response has no quote", () => {
      const s = state({
        checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
        surcharges: {
          type: "loaded",
          result: { ...loadedSurchargesWithQuote.result, buyer_currency_quote: null },
        },
      });
      expect(getStripePaymentElementMountCurrency(s)).toBe("usd");
    });

    it("mounts canonical USD when the buyer opts to save the card", () => {
      const s = state({
        checkoutPayment: buyerCurrencyPresentmentPaymentElementConfig,
        surcharges: loadedSurchargesWithQuote,
        willSaveCard: true,
      });
      expect(getStripePaymentElementMountCurrency(s)).toBe("usd");
    });

    it("always reports canonical USD on the non-presentment Payment Element lane, even mid-refresh", () => {
      // The plain lane's currency never depends on the quote, so it must never go null —
      // otherwise this change would alter mount behavior outside the presentment lane.
      expect(getStripePaymentElementMountCurrency(state())).toBe("usd");
      expect(getStripePaymentElementMountCurrency(state({ surcharges: { type: "pending" } }))).toBe("usd");
    });

    it("returns null for non-Payment-Element integrations", () => {
      expect(getStripePaymentElementMountCurrency(state({ checkoutPayment: cardElementConfig }))).toBeNull();
    });
  });
});

describe("isCardReadyToPay", () => {
  it("is ready on the saved card even though the Payment Element never mounts", () => {
    expect(isCardReadyToPay({ useSavedCard: true, useStripePaymentElement: true, paymentElementReady: false })).toBe(
      true,
    );
  });

  it("waits for the Payment Element to mount when entering a new card", () => {
    expect(isCardReadyToPay({ useSavedCard: false, useStripePaymentElement: true, paymentElementReady: false })).toBe(
      false,
    );
    expect(isCardReadyToPay({ useSavedCard: false, useStripePaymentElement: true, paymentElementReady: true })).toBe(
      true,
    );
  });

  it("is ready when the Payment Element is not in use (Card Element fallback)", () => {
    expect(isCardReadyToPay({ useSavedCard: false, useStripePaymentElement: false, paymentElementReady: false })).toBe(
      true,
    );
  });
});

describe("reduceCheckoutState", () => {
  it("stores the save-card intent without invalidating loaded surcharges", () => {
    const initial = state();

    const next = reduceCheckoutState(initial, { type: "set-value", willSaveCard: true });

    expect(next.willSaveCard).toBe(true);
    // The locked FX quote lives in the surcharges result; toggling the save-card checkbox must
    // not reset it, or every toggle would mint a fresh Stripe quote.
    expect(next.surcharges).toBe(initial.surcharges);

    const reverted = reduceCheckoutState(next, { type: "set-value", willSaveCard: false });
    expect(reverted.willSaveCard).toBe(false);
    expect(reverted.surcharges).toBe(initial.surcharges);
  });

  it("invalidates loaded surcharges for fields that change the totals", () => {
    const next = reduceCheckoutState(state(), { type: "set-value", tip: { type: "fixed", amount: 1_00 } });

    expect(next.surcharges).toEqual({ type: "pending" });
  });

  // Every field the server tax/shipping quote depends on must invalidate the loaded surcharges
  // (flipping them to "pending" is what triggers the debounced refetch) — a missing trigger
  // means the buyer-currency quote token submitted with the purchase was minted for different
  // totals than the ones charged.
  describe("total-affecting changes invalidate surcharges and queue a refetch", () => {
    it.each([
      ["country", { country: "CA" }, state()],
      ["tip", { tip: { type: "fixed", amount: 1_00 } } as const, state()],
      ["vatId", { vatId: "IE6388047V" }, state({ country: "IE" })],
      ["gift", { gift: { type: "normal", email: "friend@example.com", note: "" } } as const, state()],
      ["CA province", { state: "QC" }, state({ country: "CA", state: "ON" })],
      ["products", { products: [product({ permalink: "b" })] }, state()],
    ])("%s change flips loaded surcharges to pending", (_field, action, initial) => {
      const next = reduceCheckoutState(initial, { type: "set-value", ...action });
      expect(next.surcharges).toEqual({ type: "pending" });
    });

    it("aborts an in-flight surcharges request before invalidating", () => {
      const abort = vi.fn();
      const next = reduceCheckoutState(state({ surcharges: { type: "loading", requestId: 1, abort } }), {
        type: "set-value",
        tip: { type: "fixed", amount: 1_00 },
      });
      expect(abort).toHaveBeenCalledOnce();
      expect(next.surcharges).toEqual({ type: "pending" });
    });

    // These fences live in the reducer (rather than a ref compared in the fetch callback) so
    // they participate in dispatch ordering: any invalidation dispatched before the response
    // is already reflected in the state by the time the response's action runs.
    describe("stale surcharge response fencing", () => {
      // loadedSurcharges is declared later in the file; it blocks run after module evaluation,
      // so referencing it inside each test avoids the temporal dead zone.
      const result = () => loadedSurcharges().result;

      it("publishes a response only while its own loading state is current", () => {
        const next = reduceCheckoutState(state({ surcharges: { type: "loading", requestId: 7, abort: vi.fn() } }), {
          type: "surcharges-fetch-succeeded",
          requestId: 7,
          result: result(),
        });
        expect(next.surcharges).toEqual({ type: "loaded", result: result() });
      });

      it("drops a response whose request has been superseded by a newer one", () => {
        const initial = state({ surcharges: { type: "loading", requestId: 8, abort: vi.fn() } });
        const next = reduceCheckoutState(initial, {
          type: "surcharges-fetch-succeeded",
          requestId: 7,
          result: result(),
        });
        expect(next.surcharges).toBe(initial.surcharges);
      });

      it("drops a response after a total-affecting edit reset surcharges to pending", () => {
        // The debounce-window shape of the race: the edit's invalidation dispatched before the
        // stale response, so by the time the response's action runs the state is "pending" —
        // no ref bump (or effect flush) required for the fence to hold.
        const initial = state({ surcharges: { type: "pending" } });
        const next = reduceCheckoutState(initial, {
          type: "surcharges-fetch-succeeded",
          requestId: 7,
          result: result(),
        });
        expect(next.surcharges).toEqual({ type: "pending" });
      });

      it("lets only the current request flip the state to error", () => {
        const current = reduceCheckoutState(state({ surcharges: { type: "loading", requestId: 7, abort: vi.fn() } }), {
          type: "surcharges-fetch-failed",
          requestId: 7,
        });
        expect(current.surcharges).toEqual({ type: "error" });

        const freshLoading = { type: "loading", requestId: 8, abort: vi.fn() } as const;
        const stale = reduceCheckoutState(state({ surcharges: freshLoading }), {
          type: "surcharges-fetch-failed",
          requestId: 7,
        });
        expect(stale.surcharges).toBe(freshLoading);
      });
    });

    // The server derives the US taxable state and the TaxJar destination zip from the postal
    // code, and the purchase submits the current zip — so ANY US zip edit (not only a completed
    // 5-digit one) makes the loaded quote stale relative to what would be charged.
    it("any US zip edit flips loaded surcharges to pending", () => {
      const partial = reduceCheckoutState(state({ zipCode: "10001" }), { type: "set-value", zipCode: "1000" });
      expect(partial.surcharges).toEqual({ type: "pending" });

      const cleared = reduceCheckoutState(state({ zipCode: "10001" }), { type: "set-value", zipCode: "" });
      expect(cleared.surcharges).toEqual({ type: "pending" });
    });

    it("leaves loaded surcharges alone for changes the quote does not depend on", () => {
      const initial = state();
      // Non-US zip and non-CA state edits don't feed the server tax calculation.
      for (const action of [
        { type: "set-value", email: "other@example.com" } as const,
        { type: "set-value", fullName: "Other Buyer" } as const,
        { type: "set-value", zipCode: "SW1A 1AA" } as const,
        { type: "set-value", state: "NY" } as const,
      ]) {
        const next = reduceCheckoutState(state({ ...initial, country: "GB" }), action);
        expect(next.surcharges).toBe(initial.surcharges);
      }
    });
  });

  // The quote token is read from state.surcharges when the purchase payload is built, at the
  // END of the input → offering → validating → starting → captcha → finished pipeline. These
  // guards pin that read to the totals the buyer confirmed when the pipeline started.
  describe("stale-total submit guards", () => {
    it("refuses to offer while a surcharges refetch is queued or in flight", () => {
      for (const surcharges of [
        { type: "pending" } as const,
        { type: "loading", requestId: 1, abort: vi.fn() } as const,
      ]) {
        const next = reduceCheckoutState(state({ surcharges }), { type: "offer" });
        expect(next.status).toEqual({ type: "input", errors: new Set() });
      }
    });

    it("recovers from a failed surcharges fetch by queueing a refetch when the buyer submits", () => {
      // "error" is otherwise terminal — the refetch effect only fires on "pending" — so a
      // refusal that left it in place would permanently refuse every submit path (the native
      // PayPal button stays clickable in this state). The refusal converts the buyer's retry
      // click into an actual retry.
      for (const type of ["offer", "validate", "start-payment"] as const) {
        const next = reduceCheckoutState(state({ surcharges: { type: "error" } }), { type });
        expect(next.surcharges).toEqual({ type: "pending" });
        expect(next.status).toEqual({ type: "input", errors: new Set() });
      }
    });

    it("preserves visible field errors when refusing a submit during a refetch", () => {
      // The refusal isn't a revalidation — wiping the highlighted errors would clear them
      // without recomputing until the next real submit (Enter key / native PayPal can submit
      // inside the refetch window while errors are on screen).
      const errors = new Set(["email"]);
      for (const type of ["offer", "validate", "start-payment"] as const) {
        const next = reduceCheckoutState(
          state({ surcharges: { type: "pending" }, status: { type: "input", errors } }),
          { type },
        );
        expect(next.status).toEqual({ type: "input", errors });
      }
    });

    it("refuses to validate while a surcharges refetch is queued, cancelling back to input", () => {
      // The cross-sell offer pipeline dispatches "validate" from the "offering" status; the
      // refusal must return to "input" rather than strand the checkout mid-pipeline.
      const next = reduceCheckoutState(state({ surcharges: { type: "pending" }, status: { type: "offering" } }), {
        type: "validate",
      });
      expect(next.status).toEqual({ type: "input", errors: new Set() });
    });

    it("offers and validates normally once surcharges are loaded", () => {
      const offered = reduceCheckoutState(state(), { type: "offer" });
      expect(offered.status).toEqual({ type: "offering" });

      const validated = reduceCheckoutState(state({ status: { type: "offering" } }), { type: "validate" });
      expect(validated.status).toEqual({ type: "validating" });
    });

    it("cancels an in-progress payment when a total-affecting change lands mid-pipeline", () => {
      // e.g. the buyer changes the tip and the pipeline is already past "input" (debounce
      // window race): the quote the pipeline was confirming is no longer the one that would be
      // charged, so the payment must fall back to input instead of finishing on stale totals.
      for (const status of [
        { type: "offering" } as const,
        { type: "validating" } as const,
        { type: "starting" } as const,
      ]) {
        const next = reduceCheckoutState(state({ status }), {
          type: "set-value",
          tip: { type: "fixed", amount: 2_00 },
        });
        expect(next.surcharges).toEqual({ type: "pending" });
        expect(next.status).toEqual({ type: "input", errors: new Set() });
      }
    });

    it("does not cancel an in-progress payment for changes that keep the totals intact", () => {
      const next = reduceCheckoutState(state({ status: { type: "validating" } }), {
        type: "set-value",
        fullName: "Other Buyer",
      });
      expect(next.status).toEqual({ type: "validating" });
    });

    it("keeps a finished payment locked when a total-affecting change lands", () => {
      // "finished" means the purchase request has already been dispatched (pay() runs off a
      // status effect) and cannot be cancelled from the reducer. Resetting to "input" here would
      // not stop that charge — it would only re-enable the Pay button while the request is in
      // flight, allowing a second submission and a duplicate charge. The quote still invalidates
      // (the UI should not display totals it can no longer honor), but the status must not move.
      const finished = { type: "finished", paymentMethod: { type: "not-applicable" } } as const;
      for (const action of [
        { type: "set-value", tip: { type: "fixed", amount: 2_00 } } as const,
        { type: "set-value", gift: { type: "normal", email: "friend@example.com", note: "" } } as const,
        { type: "update-products", products: [product({ price: 2_000 })] } as const,
      ]) {
        const next = reduceCheckoutState(state({ status: finished }), action);
        expect(next.surcharges).toEqual({ type: "pending" });
        expect(next.status).toEqual(finished);
      }
    });

    it("does not cancel an in-progress wallet payment when its own address updates land", () => {
      // The Apple Pay / Google Pay sheet dispatches address set-values as part of its own
      // payment flow (shipping address change, billing details from the chosen card). Wallet
      // payments never attach the buyer-currency quote token, so there is no stale-quote risk —
      // and cancelling here would break the sheet's completion handshake.
      for (const action of [
        { type: "set-value", country: "CA" } as const,
        { type: "set-value", zipCode: "94103" } as const,
        { type: "set-value", tip: { type: "fixed", amount: 2_00 } } as const,
      ]) {
        const next = reduceCheckoutState(
          state({ status: { type: "starting" }, paymentMethod: "stripePaymentRequest" }),
          action,
        );
        // The quote still invalidates (totals may change), but the payment continues.
        expect(next.surcharges).toEqual({ type: "pending" });
        expect(next.status).toEqual({ type: "starting" });
      }
    });

    // A wallet rendered inside the Payment Element pays through the "card" payment method, so
    // its billing address can't use plain "set-value" — the total-affecting cancel above would
    // abort the payment that the address belongs to. The dedicated action invalidates the quote
    // (the held wallet payment then waits for the reload; see resolveHeldWalletPayment) while
    // leaving the in-flight status untouched.
    describe("set-wallet-billing-address", () => {
      it("invalidates surcharges on a tax-location change without cancelling the starting card payment", () => {
        for (const action of [
          { type: "set-wallet-billing-address", country: "CA", zipCode: "H2X 1Y4", state: "QC" } as const,
          // Any US ZIP change counts, ZIP+4 included — mirrors the "set-value" US ZIP rule.
          { type: "set-wallet-billing-address", country: "US", zipCode: "94103-1234", state: "CA" } as const,
        ]) {
          const next = reduceCheckoutState(state({ status: { type: "starting" } }), action);
          expect(next.surcharges).toEqual({ type: "pending" });
          expect(next.status).toEqual({ type: "starting" });
          expect(next.country).toBe(action.country);
          expect(next.zipCode).toBe(action.zipCode);
          expect(next.state).toBe(action.state);
        }
      });

      it("aborts an in-flight surcharges request before invalidating", () => {
        const abort = vi.fn();
        const next = reduceCheckoutState(state({ surcharges: { type: "loading", requestId: 1, abort } }), {
          type: "set-wallet-billing-address",
          country: "CA",
          zipCode: "H2X 1Y4",
          state: "QC",
        });
        expect(abort).toHaveBeenCalledOnce();
        expect(next.surcharges).toEqual({ type: "pending" });
      });

      it("keeps loaded surcharges when the wallet's address matches checkout's tax location", () => {
        const initial = state({ status: { type: "starting" } });
        const next = reduceCheckoutState(initial, {
          type: "set-wallet-billing-address",
          country: initial.country,
          zipCode: initial.zipCode,
          state: initial.state,
        });
        expect(next.surcharges).toBe(initial.surcharges);
        expect(next.status).toEqual({ type: "starting" });
      });
    });

    it("refuses start-payment for card payments while a surcharges refetch is queued", () => {
      // "start-payment" is dispatched unconditionally from effects (CustomerDetails on
      // "validating", the wallet payment-request watcher) — the pipeline must not re-enter on
      // a stale quote when an invalidation lands between "validate" and this action.
      const next = reduceCheckoutState(state({ surcharges: { type: "pending" } }), { type: "start-payment" });
      expect(next.status).toEqual({ type: "input", errors: new Set() });
    });

    it("lets start-payment through for wallet payments regardless of surcharge state", () => {
      // Wallets never carry the quote token; blocking them on surcharge readiness would only
      // break the payment-sheet flow.
      const next = reduceCheckoutState(
        state({ surcharges: { type: "pending" }, paymentMethod: "stripePaymentRequest" }),
        { type: "start-payment" },
      );
      expect(next.status).toEqual({ type: "starting" });
    });

    it("cancels an in-progress payment when a product update without a precomputed quote lands mid-pipeline", () => {
      // A cart update arriving after "offer"/"validate" without a fresh quote leaves surcharges
      // pending — the payload built at the end of the pipeline would carry totals the buyer
      // never confirmed, so the payment must fall back to input.
      for (const status of [
        { type: "offering" } as const,
        { type: "validating" } as const,
        { type: "starting" } as const,
      ]) {
        const next = reduceCheckoutState(state({ status }), {
          type: "update-products",
          products: [product({ price: 2_000 })],
        });
        expect(next.surcharges).toEqual({ type: "pending" });
        expect(next.status).toEqual({ type: "input", errors: new Set() });
      }
    });

    it("lets a cross-sell acceptance continue the pipeline when it carries a precomputed quote", () => {
      // Accepting an offer replaces the products mid-pipeline on purpose, and the offer flow
      // precomputes the surcharges for the accepted cart — the pipeline may continue on them.
      const next = reduceCheckoutState(state({ status: { type: "offering" } }), {
        type: "update-products",
        products: [product({ price: 2_000 })],
        surcharges: loadedSurcharges({ subtotal: 2_000 }).result,
      });
      expect(next.surcharges.type).toBe("loaded");
      expect(next.status).toEqual({ type: "offering" });
    });
  });
});

const loadedSurcharges = (
  overrides: Partial<{ subtotal: number; tax_cents: number; shipping_rate_cents: number }> = {},
) =>
  ({
    type: "loaded",
    result: {
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 0,
      tax_included_cents: 0,
      subtotal: 1_000,
      buyer_currency_quote: null,
      ...overrides,
    },
  }) as const;

describe("getChargeTodayPrice", () => {
  it("returns null until surcharges load", () => {
    expect(getChargeTodayPrice(state({ surcharges: { type: "pending" } }))).toBeNull();
  });

  it("matches the full total for carts without installments", () => {
    expect(
      getChargeTodayPrice(state({ surcharges: loadedSurcharges({ tax_cents: 100, shipping_rate_cents: 50 }) })),
    ).toBe(1_150);
  });

  it("matches the checkout table's Payment today row for an installment cart", () => {
    // $10 in 2 installments at 20% tax: the table presents the full tax with "Payment today"
    // ($5 first installment + $2 tax = $7) and "Future installments" pre-tax ($5).
    expect(
      getChargeTodayPrice(
        state({
          products: [product({ price: 1_000, payInInstallments: true, installmentPlan: { numberOfInstallments: 2 } })],
          surcharges: loadedSurcharges({ subtotal: 1_000, tax_cents: 200 }),
        }),
      ),
    ).toBe(700);
  });

  it("gives the first installment the rounding remainder", () => {
    // $100.01 in 4 installments: today charges $25.01 (three future installments of $25.00).
    expect(
      getChargeTodayPrice(
        state({
          products: [product({ price: 10_001, payInInstallments: true, installmentPlan: { numberOfInstallments: 4 } })],
          surcharges: loadedSurcharges({ subtotal: 10_001 }),
        }),
      ),
    ).toBe(2_501);
  });

  it("only splits the installment item in a mixed cart", () => {
    expect(
      getChargeTodayPrice(
        state({
          products: [
            product({ price: 1_000, payInInstallments: true, installmentPlan: { numberOfInstallments: 2 } }),
            product({ permalink: "b", price: 500 }),
          ],
          surcharges: loadedSurcharges({ subtotal: 1_500 }),
        }),
      ),
    ).toBe(1_000);
  });

  it("handles a mixed cart with tips and taxes like the checkout table does", () => {
    // $10 one-time + $200 in 2 installments, $21 fixed tip, 10% tax. The surcharges quote's
    // subtotal already includes the tip (loadSurcharges sends tipped prices). Today =
    // total ($23,100 + $2,310 tax) minus the pre-tax future installment ($10,000): $154.10.
    // Tips and taxes are entirely part of today's number, mirroring the table.
    expect(
      getChargeTodayPrice(
        state({
          products: [
            product({ permalink: "one-time", price: 1_000, hasTippingEnabled: true }),
            product({
              permalink: "installments",
              price: 20_000,
              hasTippingEnabled: true,
              payInInstallments: true,
              installmentPlan: { numberOfInstallments: 2 },
            }),
          ],
          tip: { type: "fixed", amount: 2_100 },
          surcharges: loadedSurcharges({ subtotal: 23_100, tax_cents: 2_310 }),
        }),
      ),
    ).toBe(15_410);
  });
});

describe("getFutureInstallmentsTotal", () => {
  it("is zero for carts without installment items", () => {
    expect(getFutureInstallmentsTotal(state({ products: [product({ price: 1_000 })] }))).toBe(0);
  });

  it("sums the pre-tax future payments of installment items", () => {
    // $10 in 2 installments + $200 in 2 installments: $5 + $100 remain after today.
    expect(
      getFutureInstallmentsTotal(
        state({
          products: [
            product({ price: 1_000, payInInstallments: true, installmentPlan: { numberOfInstallments: 2 } }),
            product({
              permalink: "b",
              price: 20_000,
              payInInstallments: true,
              installmentPlan: { numberOfInstallments: 2 },
            }),
          ],
        }),
      ),
    ).toBe(10_500);
  });

  it("ignores items not paying in installments even when the product offers a plan", () => {
    expect(
      getFutureInstallmentsTotal(
        state({
          products: [product({ price: 1_000, payInInstallments: false, installmentPlan: { numberOfInstallments: 2 } })],
        }),
      ),
    ).toBe(0);
  });

  // On the subscription manage page `price` is today's charge alone — the future installments
  // were never folded into it, so there is nothing to deduct from the wallet sheet's total.
  it("skips items whose plan reports remaining installments (subscription manage page)", () => {
    expect(
      getFutureInstallmentsTotal(
        state({
          products: [
            product({
              price: 0,
              renewalPriceCents: 2_500,
              payInInstallments: true,
              installmentPlan: { numberOfInstallments: 4, remainingInstallments: 2 },
            }),
          ],
        }),
      ),
    ).toBe(0);
  });
});

describe("computeTipsForLines", () => {
  const tippableProducts = (prices: number[]) =>
    prices.map((price, index) => product({ permalink: `product-${index}`, price, hasTippingEnabled: true }));
  const linesFor = (s: State) => s.products.map((item) => ({ price: item.price, permalink: item.permalink }));

  it("returns null per line when tipping is disabled", () => {
    const s = state({ products: [product({ price: 1_000 })], tip: { type: "fixed", amount: 100 } });
    expect(computeTipsForLines(s, linesFor(s))).toEqual([null]);
  });

  it("splits a fixed tip proportionally across lines", () => {
    const s = state({ products: tippableProducts([1_000, 3_000]), tip: { type: "fixed", amount: 100 } });
    expect(computeTipsForLines(s, linesFor(s))).toEqual([25, 75]);
  });

  // The regression this function exists to prevent: per-line rounding of a 1-cent fixed
  // tip across two equal items sends 1 + 1 = 2 cents even though the buyer chose 1.
  it("never sends more fixed tip than the buyer selected (two equal items, 1-cent tip)", () => {
    const s = state({ products: tippableProducts([1_000, 1_000]), tip: { type: "fixed", amount: 1 } });
    const tips = computeTipsForLines(s, linesFor(s));
    expect(tips).toEqual([1, 0]);
    expect(tips.reduce((sum: number, tip) => sum + (tip ?? 0), 0)).toBe(computeTip(s));
  });

  it("hands remainder cents to the lines with the largest fractional shares", () => {
    // Exact shares: 33.33..., 33.33..., 33.33... for 100 cents over three equal lines.
    const s = state({ products: tippableProducts([1_000, 1_000, 1_000]), tip: { type: "fixed", amount: 100 } });
    const tips = computeTipsForLines(s, linesFor(s));
    expect(tips).toEqual([34, 33, 33]);
    expect(tips.reduce((sum: number, tip) => sum + (tip ?? 0), 0)).toBe(computeTip(s));
  });

  it("sums exactly to the selected fixed tip across many uneven lines", () => {
    const prices = [199, 1_050, 333, 2_499, 61];
    const s = state({ products: tippableProducts(prices), tip: { type: "fixed", amount: 137 } });
    const tips = computeTipsForLines(s, linesFor(s));
    expect(tips.reduce((sum: number, tip) => sum + (tip ?? 0), 0)).toBe(137);
  });

  it("matches computeTipForPrice's per-line rounding for percentage tips", () => {
    const s = state({ products: tippableProducts([999, 1_001]), tip: { type: "percentage", percentage: 10 } });
    expect(computeTipsForLines(s, linesFor(s))).toEqual([100, 100]);
  });

  // isTippingEnabled requires a positive cart total, so a free cart yields no tips here —
  // the free-cart split in computeTipForFreeCart is kept for parity with computeTipForPrice.
  it("returns null per line for a free cart (tipping requires a positive total)", () => {
    const s = state({
      products: [
        product({ permalink: "product-a", price: 0, hasTippingEnabled: true }),
        product({
          permalink: "product-b",
          price: 0,
          hasTippingEnabled: true,
          creator: { id: "seller-b", name: "Seller B", profile_url: "", avatar_url: "" },
        }),
      ],
      tip: { type: "fixed", amount: 100 },
    });
    expect(computeTipsForLines(s, linesFor(s))).toEqual([null, null]);
  });

  it("returns zero tips when the fixed tip amount is not positive", () => {
    const s = state({ products: tippableProducts([1_000, 2_000]), tip: { type: "fixed", amount: 0 } });
    expect(computeTipsForLines(s, linesFor(s))).toEqual([0, 0]);
  });
});
