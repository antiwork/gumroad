import { describe, expect, it } from "vitest";

import {
  canUseStripePaymentElement,
  getStripePaymentElementAmount,
  requiresPaymentElementReusablePaymentMethod,
  requiresReusablePaymentMethodForCardCollection,
  requiresReusablePaymentMethod,
  type CheckoutPaymentConfig,
  type Product,
  type State,
} from "$app/components/Checkout/payment";

const paymentElementConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  elements_options: {
    mode: "payment",
    currency: "usd",
    payment_method_types: ["card"],
    payment_method_creation: "manual",
  },
};

const cardElementConfig: CheckoutPaymentConfig = {
  integration: "card_element",
  fallback_reason: "stripe_payment_element_flag_disabled",
  elements_options: null,
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
    },
  },
  availablePaymentMethods: [],
  paymentMethod: "card",
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

  it("falls back when a saved card is available", () => {
    expect(
      canUseStripePaymentElement(
        state({
          savedCreditCard: { type: "visa", number: "**** 4242", expiration_date: "12/30", requires_mandate: false },
        }),
      ),
    ).toBe(false);
  });

  it("falls back for multi-seller carts", () => {
    expect(
      canUseStripePaymentElement(
        state({
          products: [
            product({ creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" } }),
            product({ creator: { id: "seller-b", name: "Seller B", profile_url: "", avatar_url: "" } }),
          ],
        }),
      ),
    ).toBe(false);
  });

  it("allows reusable card flows that keep the stripe payment method contract", () => {
    expect(canUseStripePaymentElement(state({ products: [product({ subscription_id: "sub_123" })] }))).toBe(true);
    expect(canUseStripePaymentElement(state({ products: [product({ recurrence: "monthly" })] }))).toBe(true);
    expect(canUseStripePaymentElement(state({ products: [product({ nativeType: "commission" })] }))).toBe(true);
  });

  it("falls back for setup, installment, preorder, and free-trial flows", () => {
    expect(canUseStripePaymentElement(state({ products: [product({ payInInstallments: true })] }))).toBe(false);
    expect(canUseStripePaymentElement(state({ products: [product({ isPreorder: true })] }))).toBe(false);
    expect(canUseStripePaymentElement(state({ products: [product({ hasFreeTrial: true })] }))).toBe(false);
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
  it("routes recurring products through reusable setup only for Payment Element card collection", () => {
    const recurringState = state({ products: [product({ recurrence: "monthly" })] });

    expect(requiresReusablePaymentMethodForCardCollection(recurringState, true)).toBe(true);
    expect(requiresReusablePaymentMethodForCardCollection(recurringState, false)).toBe(false);
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
            },
          },
        }),
      ),
    ).toBe(1_300);
  });

  it("returns null until surcharges load", () => {
    expect(getStripePaymentElementAmount(state({ surcharges: { type: "pending" } }))).toBeNull();
  });
});
