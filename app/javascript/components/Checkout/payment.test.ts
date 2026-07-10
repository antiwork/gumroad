import { describe, expect, it } from "vitest";

import {
  canUseStripePaymentElement,
  canUseStripePaymentElementClientConfirm,
  getChargeTodayPrice,
  getFutureInstallmentsTotal,
  getStripePaymentElementAmount,
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
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
    currency: "usd",
    payment_method_types: ["card"],
    payment_method_creation: "manual",
  },
};

const futureChargePaymentElementConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  elements_options: {
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT,
    currency: "usd",
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
  elements_options: null,
};

const paymentElementClientConfirmConfig: CheckoutPaymentConfig = {
  integration: "payment_element_client_confirm",
  fallback_reason: null,
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
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
