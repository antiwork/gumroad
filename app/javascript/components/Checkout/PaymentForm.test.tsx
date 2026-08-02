// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { StateContext, type CheckoutPaymentConfig, type State } from "$app/components/Checkout/payment";
import { PaymentForm } from "$app/components/Checkout/PaymentForm";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

// Keeps the render free of network and third-party scripts: the scenarios below are free
// purchases, so the Stripe/PayPal payment subtrees never mount, but the hooks still run.
vi.mock("$app/data/braintree_client_token_data", () => ({ useBraintreeToken: () => ({ type: "not-available" }) }));
vi.mock("$app/utils/stripe_loader", () => ({ getCheckoutStripeInstance: vi.fn(), getStripeInstance: vi.fn() }));
vi.mock("$app/components/useRecaptcha", () => ({
  useRecaptcha: () => ({ execute: vi.fn(), container: null }),
  RECAPTCHA_UNAVAILABLE_MESSAGE: "unavailable",
  RecaptchaUnavailableError: class extends Error {},
  RecaptchaCancelledError: class extends Error {},
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const cardElementConfig: CheckoutPaymentConfig = {
  integration: "card_element",
  fallback_reason: "not_checkout",
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: false,
  flat_payment_methods: false,
  elements_options: null,
};

const state = (overrides: Partial<State> = {}): State => ({
  products: [
    {
      permalink: "product-a",
      name: "Product A",
      creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" },
      quantity: 1,
      price: 0,
      payInInstallments: false,
      requireShipping: false,
      customFields: [{ id: "field-1", type: "text", name: "Nickname", required: true, collect_per_product: false }],
      bundleProductCustomFields: [],
      supportsPaypal: null,
      testPurchase: false,
      requirePayment: false,
      hasFreeTrial: false,
      hasTippingEnabled: false,
      isPreorder: false,
      canGift: false,
      nativeType: "digital",
      recurrence: null,
      shippableCountryCodes: [],
    },
  ],
  countries: { US: "United States" },
  usStates: [],
  caProvinces: [],
  tipOptions: [],
  country: "US",
  email: "buyer@example.com",
  vatId: "",
  fullName: "",
  address: "",
  city: "",
  state: "",
  zipCode: "",
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
      subtotal: 0,
      buyer_currency_quote: null,
    },
  },
  availablePaymentMethods: [],
  paymentMethod: "card",
  paymentElementType: "card",
  willSaveCard: false,
  usingSavedCard: false,
  savedCreditCard: null,
  checkoutPayment: cardElementConfig,
  checkoutPaymentStale: false,
  resumeSubmitAfterCheckoutPayment: false,
  validationFailedCount: 0,
  status: { type: "input", errors: new Set() },
  recaptchaKey: null,
  recaptchaScoreBased: false,
  paypalClientId: "",
  tip: { type: "percentage", percentage: 0 },
  emailTypoSuggestion: null,
  acknowledgedEmails: new Set(),
  requireEmailTypoAcknowledgment: false,
  ...overrides,
});

const renderPaymentForm = (checkoutState: State) => {
  const view = (s: State) => (
    <LoggedInUserProvider value={null}>
      <StateContext.Provider value={[s, vi.fn()] as const}>
        <PaymentForm />
      </StateContext.Provider>
    </LoggedInUserProvider>
  );
  const utils = render(view(checkoutState));
  return { ...utils, rerenderWith: (s: State) => utils.rerender(view(s)) };
};

describe("PaymentForm validation-failure feedback", () => {
  const scrollIntoView = vi.fn();

  beforeEach(() => {
    scrollIntoView.mockClear();
    Element.prototype.scrollIntoView = scrollIntoView;
  });
  afterEach(cleanup);

  const failedState = (validationFailedCount: number) =>
    state({
      status: { type: "input", errors: new Set(["customFields.field-1"]) },
      validationFailedCount,
    });

  it("scrolls the first errored field into view and focuses it", () => {
    renderPaymentForm(failedState(1));

    const field = screen.getByLabelText("Nickname");
    expect(field.getAttribute("aria-invalid")).toBe("true");
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(scrollIntoView.mock.instances[0]).toBe(field);
    expect(document.activeElement).toBe(field);
  });

  it("re-scrolls when another submit is refused, but not on unrelated re-renders", () => {
    const { rerenderWith } = renderPaymentForm(failedState(1));
    expect(scrollIntoView).toHaveBeenCalledTimes(1);

    // A re-render with the same failure count (the buyer typing into some other field) must not
    // yank the viewport back to the errored field.
    rerenderWith(failedState(1));
    expect(scrollIntoView).toHaveBeenCalledTimes(1);

    rerenderWith(failedState(2));
    expect(scrollIntoView).toHaveBeenCalledTimes(2);
  });

  it("does not scroll while nothing is flagged", () => {
    renderPaymentForm(state());
    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("tells the buyer the flagged field is required", () => {
    const { rerenderWith } = renderPaymentForm(state());
    expect(screen.queryByText("This field is required.")).toBeNull();

    rerenderWith(failedState(1));
    expect(screen.getByText("This field is required.")).toBeTruthy();
    expect(screen.getByLabelText("Nickname").getAttribute("aria-describedby")).toBe(
      screen.getByText("This field is required.").id,
    );
  });
});
