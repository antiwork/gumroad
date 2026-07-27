import { describe, expect, it } from "vitest";

import type { PurchasePaymentMethod } from "$app/data/purchase";

import { resolveHeldWalletPayment } from "$app/components/Checkout/heldWalletPayment";
import {
  STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
  type CheckoutPaymentConfig,
  type Product,
  type State,
} from "$app/components/Checkout/payment";

const paymentElementConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: true,
  flat_payment_methods: true,
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
    currency: "usd",
    payment_method_types: ["card"],
    payment_method_creation: "manual",
    stripe_link_enabled: false,
  },
};

const clientConfirmConfig: CheckoutPaymentConfig = {
  integration: "payment_element_client_confirm",
  fallback_reason: null,
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: true,
  flat_payment_methods: true,
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
    currency: "usd",
    presentment_amount_cents: null,
    listed_currency_display: null,
    payment_method_types: ["card"],
    stripe_link_enabled: false,
    stripe_connect_account_id: null,
  },
};

const product = (): Product => ({
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
});

const loadedSurcharges = (taxCents: number): State["surcharges"] => ({
  type: "loaded",
  result: {
    vat_id_valid: false,
    has_vat_id_input: false,
    shipping_rate_cents: 0,
    tax_cents: taxCents,
    tax_included_cents: 0,
    subtotal: 1_000,
    buyer_currency_quote: null,
  },
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
  surcharges: loadedSurcharges(0),
  availablePaymentMethods: [],
  paymentMethod: "card",
  paymentElementType: "card",
  willSaveCard: false,
  savedCreditCard: null,
  checkoutPayment: paymentElementConfig,
  status: { type: "starting" },
  recaptchaKey: null,
  paypalClientId: "",
  tip: { type: "percentage", percentage: 0 },
  emailTypoSuggestion: null,
  acknowledgedEmails: new Set(),
  requireEmailTypoAcknowledgment: false,
  ...overrides,
});

const serverConfirmPaymentMethod: PurchasePaymentMethod = { type: "not-applicable" };
const clientConfirmPaymentMethod: PurchasePaymentMethod = {
  type: "payment-element-client-confirm",
  confirmationTokenId: "ctoken_123",
  cardCountry: "US",
  walletType: "apple_pay",
  mountCurrency: "usd",
};

// The held payment was tokenized while surcharges showed no tax (total 1000), so those are the
// element amount and checkout total the buyer approved.
const held = <PaymentMethod>(paymentMethod: PaymentMethod) => ({
  paymentMethod,
  approvedAmount: 1_000,
  approvedTotal: 1_000,
});

describe("resolveHeldWalletPayment", () => {
  describe.each([
    ["server-confirm wallet lane", paymentElementConfig, serverConfirmPaymentMethod],
    ["client-confirm wallet lane", clientConfirmConfig, clientConfirmPaymentMethod],
  ])("%s", (_lane, checkoutPayment, paymentMethod) => {
    it("waits while surcharges reload for the wallet's new tax location", () => {
      expect(
        resolveHeldWalletPayment(state({ checkoutPayment, surcharges: { type: "pending" } }), held(paymentMethod)),
      ).toEqual({ type: "wait" });
      expect(
        resolveHeldWalletPayment(
          state({ checkoutPayment, surcharges: { type: "loading", abort: () => {} } }),
          held(paymentMethod),
        ),
      ).toEqual({ type: "wait" });
    });

    it("continues with the held payment when the recalculated total matches the wallet-approved one", () => {
      expect(
        resolveHeldWalletPayment(state({ checkoutPayment, surcharges: loadedSurcharges(0) }), held(paymentMethod)),
      ).toEqual({ type: "continue", paymentMethod });
    });

    it("requires re-confirmation when the recalculated total differs from the wallet-approved one", () => {
      expect(
        resolveHeldWalletPayment(state({ checkoutPayment, surcharges: loadedSurcharges(200) }), held(paymentMethod)),
      ).toEqual({ type: "re-confirm" });
    });

    it("requires re-confirmation when the surcharges reload fails — the totals can't be shown to agree", () => {
      expect(
        resolveHeldWalletPayment(state({ checkoutPayment, surcharges: { type: "error" } }), held(paymentMethod)),
      ).toEqual({ type: "re-confirm" });
    });

    it("aborts when the submission is no longer in flight", () => {
      expect(
        resolveHeldWalletPayment(
          state({ checkoutPayment, status: { type: "input", errors: new Set() } }),
          held(paymentMethod),
        ),
      ).toEqual({ type: "abort" });
    });
  });

  // The method-forced surface (UPI, iDEAL, ...) mounts the element with a fixed server-rendered
  // presentment amount that cannot move when taxes are recalculated — so the tax-change guard
  // must compare checkout's own total there, not the element amount (which trivially matches).
  describe("method-forced client-confirm lane (fixed presentment amount)", () => {
    const methodForcedConfig: CheckoutPaymentConfig = {
      ...clientConfirmConfig,
      elements_options: {
        ...clientConfirmConfig.elements_options,
        currency: "inr",
        presentment_amount_cents: 89_000,
        payment_method_types: ["upi"],
      },
    };
    const methodForcedHeld = {
      paymentMethod: clientConfirmPaymentMethod,
      approvedAmount: 89_000,
      approvedTotal: 1_000,
    };

    it("continues when the recalculated checkout total still matches the approved one", () => {
      expect(
        resolveHeldWalletPayment(
          state({ checkoutPayment: methodForcedConfig, surcharges: loadedSurcharges(0) }),
          methodForcedHeld,
        ),
      ).toEqual({ type: "continue", paymentMethod: clientConfirmPaymentMethod });
    });

    it("requires re-confirmation when the adopted address changes the tax even though the element amount is constant", () => {
      expect(
        resolveHeldWalletPayment(
          state({ checkoutPayment: methodForcedConfig, surcharges: loadedSurcharges(180) }),
          methodForcedHeld,
        ),
      ).toEqual({ type: "re-confirm" });
    });
  });
});
