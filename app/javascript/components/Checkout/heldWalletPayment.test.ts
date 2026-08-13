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
    buyer_currency_presentment: false,
    payment_method_types: ["card"],
    payment_method_creation: "manual",
    stripe_link_enabled: false,
  },
};

const clientConfirmConfig: CheckoutPaymentConfig = {
  integration: "payment_element_client_confirm",
  fallback_reason: null,
  recurring_upi_registration: false,
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
    payment_method_list_token: null,
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
  buyerCurrency: null,
  saveAddress: false,
  gift: null,
  customFieldValues: {},
  surcharges: loadedSurcharges(0),
  availablePaymentMethods: [],
  paymentMethod: "card",
  paymentElementType: "card",
  willSaveCard: false,
  usingSavedCard: false,
  savedCreditCard: null,
  checkoutPayment: paymentElementConfig,
  status: { type: "starting" },
  recaptchaKey: null,
  recaptchaScoreBased: false,
  recaptchaChallengeKey: null,
  paypalClientId: "",
  tip: { type: "percentage", percentage: 0 },
  emailTypoSuggestion: null,
  acknowledgedEmails: new Set(),
  requireEmailTypoAcknowledgment: false,
  checkoutPaymentStale: false,
  resumeSubmitAfterCheckoutPayment: false,
  validationFailedCount: 0,
  ...overrides,
});

const serverConfirmPaymentMethod: PurchasePaymentMethod = { type: "not-applicable" };
const clientConfirmPaymentMethod: PurchasePaymentMethod = {
  type: "payment-element-client-confirm",
  confirmationTokenId: "ctoken_123",
  cardCountry: "US",
  walletType: "apple_pay",
  mountCurrency: "usd",
  methodListToken: null,
  selectedMethodType: "card",
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
          state({ checkoutPayment, surcharges: { type: "loading", requestId: 1, abort: () => {} } }),
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

  // The buyer-currency (FX-quoted) presentment lane. Here the element mounts in the buyer's
  // currency at the quote's locked total, so `approvedAmount` — which getStripePaymentElementAmount
  // resolves from the quote — is the presentment number the wallet sheet displayed. That makes the
  // existing comparison already correct for this lane; these cases pin it, because nothing else
  // covers it and the safety property is invisible: a regression here would not fail any other
  // test, it would charge a buyer a total they never approved.
  describe("buyer-currency presentment lane (FX-quoted element mount)", () => {
    const fxConfig: CheckoutPaymentConfig = {
      ...paymentElementConfig,
      elements_options: {
        ...paymentElementConfig.elements_options,
        buyer_currency_presentment: true,
      },
    };

    // A loaded surcharge response carrying an FX quote, with the presentment total tracking the
    // canonical total at rate 1.25 so the quote stays internally consistent (the display helper
    // rejects a quote whose line allocations do not reconcile to its total).
    const loadedWithQuote = (taxCents: number): State["surcharges"] => {
      const canonicalTotal = 1_000 + taxCents;
      const presentmentTotal = Math.round(canonicalTotal * 1.25);
      const presentmentTax = Math.round(taxCents * 1.25);
      return {
        type: "loaded",
        result: {
          vat_id_valid: false,
          has_vat_id_input: false,
          shipping_rate_cents: 0,
          tax_cents: taxCents,
          tax_included_cents: 0,
          subtotal: 1_000,
          buyer_currency_quote: {
            token: "quote-token",
            currency: "cad",
            canonical_total_cents: canonicalTotal,
            presentment_total_cents: presentmentTotal,
            rate: 1.25,
            subunit_to_unit: 100,
            expires_at: "2099-01-01T00:00:00Z",
            line_allocations: [
              {
                permalink: "product-a",
                price_cents: presentmentTotal - presentmentTax,
                tip_cents: 0,
                tax_cents: presentmentTax,
                shipping_cents: 0,
                total_cents: presentmentTotal,
              },
            ],
          },
        },
      };
    };

    // Approved at zero tax: the sheet showed the locked CA$12.50 (1250 minor units) while
    // checkout's own canonical total was US$10.00.
    const fxHeld = {
      paymentMethod: serverConfirmPaymentMethod,
      approvedAmount: 1_250,
      approvedTotal: 1_000,
    };

    it("continues when the reloaded quote still matches the approved presentment total", () => {
      expect(
        resolveHeldWalletPayment(state({ checkoutPayment: fxConfig, surcharges: loadedWithQuote(0) }), fxHeld),
      ).toEqual({ type: "continue", paymentMethod: serverConfirmPaymentMethod });
    });

    it("requires re-confirmation when the adopted address changes the tax", () => {
      expect(
        resolveHeldWalletPayment(state({ checkoutPayment: fxConfig, surcharges: loadedWithQuote(200) }), fxHeld),
      ).toEqual({ type: "re-confirm" });
    });

    // The quote can disappear on reload (expired, or Stripe rejected the re-quote). The element
    // amount then falls back to the canonical USD total, which no longer equals the presentment
    // amount the buyer approved — so this must never continue, or a wallet sheet showing CA$12.50
    // would be charged US$10.00.
    it("requires re-confirmation when the quote is gone from the reloaded surcharges", () => {
      expect(
        resolveHeldWalletPayment(state({ checkoutPayment: fxConfig, surcharges: loadedSurcharges(0) }), fxHeld),
      ).toEqual({ type: "re-confirm" });
    });
  });
});
