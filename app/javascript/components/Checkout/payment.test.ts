import { describe, expect, it } from "vitest";

import {
  canUseStripePaymentElement,
  getStripePaymentElementAmount,
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

  it("falls back for reusable payment method flows", () => {
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
    expect(canUseStripePaymentElement(state({ products: [product({ subscription_id: "sub_123" })] }))).toBe(false);
    expect(canUseStripePaymentElement(state({ products: [product({ recurrence: "monthly" })] }))).toBe(false);
    expect(canUseStripePaymentElement(state({ products: [product({ nativeType: "commission" })] }))).toBe(false);
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
