// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  reduceCheckoutState,
  StateContext,
  type CheckoutPaymentConfig,
  type State,
} from "$app/components/Checkout/payment";
import { PaymentForm } from "$app/components/Checkout/PaymentForm";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));
vi.stubGlobal("SSR", false);

const paymentElementInputRender = vi.hoisted<{ setupFutureUsage: "off_session" | undefined }>(() => ({
  setupFutureUsage: undefined,
}));

const paypalMock = vi.hoisted<{
  buttonsConfig: null | { onApprove: (data: { billingToken: string }) => Promise<void> };
  createBillingAgreement: ReturnType<typeof vi.fn>;
  getPaymentMethodResult: ReturnType<typeof vi.fn>;
  getReusablePaymentMethodResult: ReturnType<typeof vi.fn>;
  loadScript: ReturnType<typeof vi.fn>;
  render: ReturnType<typeof vi.fn>;
}>(() => ({
  buttonsConfig: null,
  createBillingAgreement: vi.fn(),
  getPaymentMethodResult: vi.fn(),
  getReusablePaymentMethodResult: vi.fn(),
  loadScript: vi.fn(),
  render: vi.fn(),
}));

// Keeps the render free of network and third-party scripts. The recurring UPI case captures the
// Payment Element props, while the other scenarios are free purchases whose payment subtrees do not mount.
vi.mock("@stripe/react-stripe-js", () => ({ useStripe: () => null }));
vi.mock("@paypal/paypal-js", () => ({ loadScript: paypalMock.loadScript }));
vi.mock("$app/data/paypal", () => ({
  createBillingAgreement: paypalMock.createBillingAgreement,
  createBillingAgreementToken: vi.fn(),
}));
vi.mock("$app/data/payment_method_result", () => ({
  getPaymentMethodResult: paypalMock.getPaymentMethodResult,
  getPaymentRequestPaymentMethodResult: vi.fn(),
  getReusablePaymentMethodResult: paypalMock.getReusablePaymentMethodResult,
  getReusablePaymentRequestPaymentMethodResult: vi.fn(),
}));
vi.mock("$app/data/braintree_client_token_data", () => ({ useBraintreeToken: () => ({ type: "not-available" }) }));
vi.mock("$app/utils/stripe_loader", () => ({ getCheckoutStripeInstance: vi.fn(), getStripeInstance: vi.fn() }));
vi.mock("$app/components/Checkout/CreditCardInput", () => ({
  CreditCardInput: () => null,
  StripeElementsProvider: ({ children }: { children: React.ReactNode }) => children,
}));
vi.mock("$app/components/Checkout/PaymentElementInput", () => ({
  PaymentElementInput: ({ setupFutureUsage }: { setupFutureUsage?: "off_session" | undefined }) => {
    paymentElementInputRender.setupFutureUsage = setupFutureUsage;
    return null;
  },
}));
vi.mock("$app/components/useRecaptcha", () => ({
  useRecaptcha: () => ({ execute: vi.fn(), container: null }),
  RecaptchaDisclosure: () => null,
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
  buyerCurrency: null,
  buyerCurrencyRemint: null,
  unavailableBuyerCurrency: null,
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
  recaptchaChallengeKey: null,
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

// Applies reducer updates so a second native PayPal approval sees the new tax location.
const StatefulPaymentForm = ({
  initial,
  harness,
}: {
  initial: State;
  harness: { dispatch: React.Dispatch<Parameters<typeof reduceCheckoutState>[1]> };
}) => {
  const [checkoutState, dispatch] = React.useReducer(reduceCheckoutState, initial);
  harness.dispatch = dispatch;
  return (
    <LoggedInUserProvider value={null}>
      <StateContext.Provider value={[checkoutState, dispatch]}>
        <PaymentForm />
      </StateContext.Provider>
    </LoggedInUserProvider>
  );
};

describe("PaymentForm validation-failure feedback", () => {
  const scrollIntoView = vi.fn();

  beforeEach(() => {
    scrollIntoView.mockClear();
    paymentElementInputRender.setupFutureUsage = undefined;
    paypalMock.buttonsConfig = null;
    paypalMock.createBillingAgreement.mockReset();
    paypalMock.getPaymentMethodResult.mockReset();
    paypalMock.getReusablePaymentMethodResult.mockReset();
    paypalMock.loadScript.mockReset();
    paypalMock.render.mockReset();
    paypalMock.loadScript.mockResolvedValue({
      Buttons: (config: { onApprove: (data: { billingToken: string }) => Promise<void> }) => {
        paypalMock.buttonsConfig = config;
        return { render: paypalMock.render };
      },
    });
    paypalMock.createBillingAgreement.mockResolvedValue({
      id: "agreement-id",
      payer: {
        payer_info: {
          email: "paypal-buyer@example.com",
          payer_id: "payer-id",
          billing_address: { country_code: "DE", postal_code: "10115" },
          first_name: "PayPal",
          last_name: "Buyer",
        },
      },
    });
    paypalMock.getPaymentMethodResult.mockResolvedValue({ type: "paypal", reusable: false });
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

  it("declares off-session future use for the recurring UPI client-confirm lane", () => {
    type ClientConfirmPayment = Extract<CheckoutPaymentConfig, { integration: "payment_element_client_confirm" }>;
    const checkoutPayment: ClientConfirmPayment = {
      integration: "payment_element_client_confirm",
      fallback_reason: null,
      recurring_upi_registration: true,
      disable_wallets: true,
      request_apple_pay_merchant_tokens: false,
      payment_element_wallets: false,
      flat_payment_methods: true,
      elements_options: {
        stripe_elements_mode: "payment",
        currency: "inr",
        presentment_amount_cents: 73_000,
        listed_currency_display: { currency: "inr", subunit_to_unit: 100 },
        payment_method_types: ["card", "upi"],
        payment_method_list_token: null,
        stripe_link_enabled: false,
        stripe_connect_account_id: null,
      },
    };
    const checkoutState = state();
    const [product] = checkoutState.products;
    if (product === undefined) throw new Error("Expected a checkout product");
    if (checkoutState.surcharges.type !== "loaded") throw new Error("Expected loaded surcharges");

    renderPaymentForm({
      ...checkoutState,
      products: [
        {
          ...product,
          price: 73_000,
          requirePayment: true,
          recurrence: "monthly",
          listedPriceCents: 73_000,
        },
      ],
      surcharges: {
        type: "loaded",
        result: { ...checkoutState.surcharges.result, subtotal: 73_000 },
      },
      checkoutPayment,
    });

    expect(paymentElementInputRender.setupFutureUsage).toBe("off_session");
  });

  it("does not reuse a native PayPal agreement after PayPal changes the tax location", async () => {
    const surchargeResult = {
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 190,
      tax_included_cents: 0,
      subtotal: 1_000,
      buyer_currency_quote: null,
    };
    const checkoutState = state({
      country: "US",
      zipCode: "10001",
      paymentMethod: "paypal",
      paypalClientId: "paypal-client-id",
      status: { type: "starting" },
      products: state().products.map((product) => ({
        ...product,
        price: 1_000,
        requirePayment: true,
        supportsPaypal: "native" as const,
      })),
    });
    paypalMock.createBillingAgreement.mockImplementation(async (token: string) => ({
      id: token === "billing-token-2" ? "agreement-id-2" : "agreement-id-1",
      payer: {
        payer_info: {
          email: "paypal-buyer@example.com",
          payer_id: "payer-id",
          billing_address: { country_code: "DE", postal_code: "10115" },
          first_name: "PayPal",
          last_name: "Buyer",
        },
      },
    }));
    const harness = {
      dispatch: ((_action: Parameters<typeof reduceCheckoutState>[1]) => undefined) as React.Dispatch<
        Parameters<typeof reduceCheckoutState>[1]
      >,
    };
    render(<StatefulPaymentForm initial={checkoutState} harness={harness} />);

    await waitFor(() => expect(paypalMock.buttonsConfig).not.toBeNull());
    await paypalMock.buttonsConfig?.onApprove({ billingToken: "billing-token-1" });

    expect(paypalMock.getPaymentMethodResult).not.toHaveBeenCalled();
    await waitFor(() =>
      expect(
        screen.getByText(
          "PayPal updated your tax location. Review the updated total below, then click PayPal again to continue.",
        ),
      ).toBeTruthy(),
    );

    // Simulate the pending tax quote landing, then the buyer clicking PayPal again.
    harness.dispatch({
      type: "set-value",
      surcharges: { type: "loaded", result: surchargeResult },
    });
    harness.dispatch({ type: "start-payment" });
    await waitFor(() => expect(screen.getByLabelText("Email address")).toHaveProperty("disabled", true));

    await paypalMock.buttonsConfig?.onApprove({ billingToken: "billing-token-2" });

    await waitFor(() => expect(paypalMock.getPaymentMethodResult).toHaveBeenCalledOnce());
    expect(paypalMock.getPaymentMethodResult).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "paypal-native",
        info: expect.objectContaining({
          billingToken: "billing-token-2",
          agreementId: "agreement-id-2",
        }),
      }),
    );
    expect(paypalMock.getPaymentMethodResult).not.toHaveBeenCalledWith(
      expect.objectContaining({
        info: expect.objectContaining({ agreementId: "agreement-id-1" }),
      }),
    );
  });

  // Mirrors Checkout/index.tsx: tip and gift inputs render as siblings of PaymentForm, all of them
  // inside the [data-checkout-scope] wrapper. `before` renders outside that wrapper, standing in
  // for the rest of the page.
  const renderCheckoutPage = ({
    before,
    siblings,
    value,
  }: {
    before?: React.ReactNode;
    siblings?: React.ReactNode;
    value: State;
  }) =>
    render(
      <LoggedInUserProvider value={null}>
        {before}
        <div data-checkout-scope>
          {siblings}
          <StateContext.Provider value={[value, vi.fn()]}>
            <PaymentForm />
          </StateContext.Provider>
        </div>
      </LoggedInUserProvider>,
    );

  const tipField = <input aria-label="Custom tip" aria-invalid="true" data-testid="tip-outside-payment-form" />;

  it("scans the whole checkout so fields flagged outside the payment form (tip, gift) are found", () => {
    renderCheckoutPage({
      siblings: tipField,
      value: state({ status: { type: "input", errors: new Set(["tip"]) }, validationFailedCount: 1 }),
    });

    const field = screen.getByTestId("tip-outside-payment-form");
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(scrollIntoView.mock.instances[0]).toBe(field);
    expect(document.activeElement).toBe(field);
  });

  it("sends the buyer to the first unmet field in page order, not the first one inside the form", () => {
    // Tip and gift render before PaymentForm in Checkout/index.tsx. When both a tip and a custom
    // field are flagged, the earlier tip field must win — a form-subtree-first scan would skip it.
    renderCheckoutPage({
      siblings: tipField,
      value: state({
        status: { type: "input", errors: new Set(["tip", "customFields.field-1"]) },
        validationFailedCount: 1,
      }),
    });

    expect(screen.getByLabelText("Nickname").getAttribute("aria-invalid")).toBe("true");
    const field = screen.getByTestId("tip-outside-payment-form");
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(scrollIntoView.mock.instances[0]).toBe(field);
    expect(document.activeElement).toBe(field);
  });

  it("ignores an invalid control outside the checkout, however early it sits in the page", () => {
    // A page-wide scan would hand focus to this instead, leaving the buyer's actual blocker
    // unfocused and off-screen.
    renderCheckoutPage({
      before: <input aria-label="Unrelated" aria-invalid="true" data-testid="outside-checkout" />,
      value: failedState(1),
    });

    const field = screen.getByLabelText("Nickname");
    expect(screen.getByTestId("outside-checkout").getAttribute("aria-invalid")).toBe("true");
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(scrollIntoView.mock.instances[0]).toBe(field);
    expect(document.activeElement).toBe(field);
  });

  it("skips a disabled invalid control and lands on the one the buyer can act on", () => {
    renderCheckoutPage({
      siblings: <input aria-label="Disabled tip" aria-invalid="true" disabled data-testid="disabled-field" />,
      value: failedState(1),
    });

    const field = screen.getByLabelText("Nickname");
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(scrollIntoView.mock.instances[0]).toBe(field);
    expect(document.activeElement).toBe(field);
  });

  it("skips a visibility-hidden invalid control, which only the named visibility check catches", () => {
    // happy-dom lacks checkVisibility, so mimic the spec: a `visibility: hidden` element reports
    // invisible only when the check is requested by option — an argless call still returns true.
    const original = Element.prototype.checkVisibility;
    Element.prototype.checkVisibility = function (this: Element, options?: CheckVisibilityOptions) {
      const hiddenByVisibility = this instanceof HTMLElement && this.style.visibility === "hidden";
      return !(hiddenByVisibility && (options?.visibilityProperty === true || options?.checkVisibilityCSS === true));
    };
    try {
      renderCheckoutPage({
        siblings: (
          <input
            aria-label="Hidden tip"
            aria-invalid="true"
            style={{ visibility: "hidden" }}
            data-testid="hidden-field"
          />
        ),
        value: failedState(1),
      });

      const field = screen.getByLabelText("Nickname");
      expect(scrollIntoView).toHaveBeenCalledTimes(1);
      expect(scrollIntoView.mock.instances[0]).toBe(field);
      expect(document.activeElement).toBe(field);
    } finally {
      Element.prototype.checkVisibility = original;
    }
  });

  it("lands on the State select when it is the unmet field, not only on invalid inputs", () => {
    // The US/CA State field renders as a native select — an input-only scan finds nothing and
    // the refused Pay is silent again.
    const base = state();
    renderPaymentForm({
      ...base,
      products: base.products.map((p) => ({ ...p, requireShipping: true, shippableCountryCodes: ["US"] })),
      usStates: ["AL", "CA"],
      status: { type: "input", errors: new Set(["state"]) },
      validationFailedCount: 1,
    });

    const field = screen.getByLabelText("State");
    expect(field.tagName).toBe("SELECT");
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    // isSameNode / id, not toBe: happy-dom hands out a Proxy per select lookup (for indexed
    // option access), so reference equality between lookups fails on the same node.
    const scrolled = scrollIntoView.mock.instances[0];
    expect(scrolled instanceof Node && field.isSameNode(scrolled)).toBe(true);
    expect(document.activeElement?.id).toBe(field.id);
  });

  it("still scans its own subtree when rendered with no checkout ancestor (preview dashboard)", () => {
    renderPaymentForm(failedState(1));

    const field = screen.getByLabelText("Nickname");
    expect(scrollIntoView.mock.instances[0]).toBe(field);
    expect(document.activeElement).toBe(field);
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
