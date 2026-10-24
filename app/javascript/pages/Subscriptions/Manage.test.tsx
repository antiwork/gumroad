// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import SubscriptionsManage from "$app/pages/Subscriptions/Manage";

import { LoggedInUserProvider } from "$app/components/LoggedInUser";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));
vi.stubGlobal("SSR", false);

// Stands in for Inertia's page host. Matches @inertiajs/core 2.3.13: `reload` always preserves
// component state, and any other visit remounts the page unless it asks to preserve state.
const inertia = vi.hoisted(() => {
  const host: {
    props: Record<string, unknown>;
    serverProps: Record<string, unknown>;
    key: number;
    rerender: () => void;
    respond: (preserveState: boolean) => void;
    reload: () => void;
    visit: (url: string, options?: { preserveState?: boolean }) => void;
  } = {
    props: {},
    serverProps: {},
    key: 0,
    rerender: () => {},
    respond(preserveState) {
      host.props = host.serverProps;
      if (!preserveState) host.key += 1;
      host.rerender();
    },
    reload: vi.fn(() => host.respond(true)),
    visit: vi.fn((_url: string, options?: { preserveState?: boolean }) =>
      host.respond(options?.preserveState === true),
    ),
  };
  return host;
});
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: inertia.props }),
  useForm: () => ({ post: vi.fn() }),
  router: {
    reload: inertia.reload,
    visit: inertia.visit,
    get: vi.fn(),
  },
}));

const mocks = vi.hoisted(() => ({
  updateSubscription: vi.fn(),
  newCard: { type: "new", cardParamsResult: { type: "cc", cardParams: { status: "success", reusable: true } } },
}));
vi.mock("$app/data/subscription", () => ({ updateSubscription: mocks.updateSubscription }));
vi.mock("$app/data/purchase", () => ({ confirmLineItem: vi.fn() }));
vi.mock("$app/data/customer_surcharge", () => ({
  getSurcharges: vi.fn(() =>
    Promise.resolve({
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 0,
      tax_included_cents: 0,
      subtotal: 0,
      buyer_currency_quote: null,
    }),
  ),
}));
vi.mock("$app/data/payment_method_result", () => ({
  getPaymentMethodResult: vi.fn(() => Promise.resolve(mocks.newCard)),
  getReusablePaymentMethodResult: vi.fn(() => Promise.resolve(mocks.newCard)),
  getPaymentRequestPaymentMethodResult: vi.fn(),
  getReusablePaymentRequestPaymentMethodResult: vi.fn(),
}));
vi.mock("@stripe/react-stripe-js", () => ({ useStripe: () => null }));
vi.mock("@paypal/paypal-js", () => ({
  loadScript: () => Promise.resolve({ Buttons: () => ({ render: vi.fn() }) }),
}));
vi.mock("$app/data/paypal", () => ({ createBillingAgreement: vi.fn(), createBillingAgreementToken: vi.fn() }));
vi.mock("$app/data/braintree_client_token_data", () => ({ useBraintreeToken: () => ({ type: "not-available" }) }));
vi.mock("$app/utils/stripe_loader", () => ({ getCheckoutStripeInstance: vi.fn(), getStripeInstance: vi.fn() }));
vi.mock("$app/components/Checkout/CreditCardInput", () => ({
  CreditCardInput: ({
    savedCreditCard,
    useSavedCard,
    onReady,
  }: {
    savedCreditCard: { number: string } | null;
    useSavedCard: boolean;
    onReady: (element: object) => void;
  }) => {
    React.useEffect(() => {
      onReady({});
    }, [onReady]);
    return savedCreditCard && useSavedCard ? <div aria-label="Saved credit card">{savedCreditCard.number}</div> : null;
  },
  StripeElementsProvider: ({ children }: { children: React.ReactNode }) => children,
}));
vi.mock("$app/components/useRecaptcha", () => ({
  useRecaptcha: () => ({ execute: vi.fn(), container: null }),
  RecaptchaDisclosure: () => null,
  RECAPTCHA_UNAVAILABLE_MESSAGE: "unavailable",
  RecaptchaUnavailableError: class extends Error {},
  RecaptchaCancelledError: class extends Error {},
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn(), dismissAlert: vi.fn() }));

const pageProps = (overrides: Record<string, unknown> = {}) => ({
  product: {
    id: "product-id",
    permalink: "membership",
    name: "Synthetic membership",
    native_type: "membership",
    require_shipping: false,
    custom_fields: [],
    supports_paypal: "native",
    paypal_card_funding_disabled: false,
    link_disabled: false,
    creator: { id: "seller-id", name: "Seller", profile_url: "", avatar_url: "" },
    currency_code: "usd",
    options: [],
    price_cents: 500,
    is_tiered_membership: false,
    is_legacy_subscription: false,
    is_multiseat_license: false,
    recurrences: [{ id: "price-monthly", recurrence: "monthly", price_cents: 500 }],
    pwyw: null,
    installment_plan: null,
    exchange_rate: 1,
    shippable_country_codes: [],
  },
  subscription: {
    id: "subscription-id",
    recurrence: "monthly",
    option_id: null,
    price: 500,
    pre_discount_price: 500,
    quantity: 1,
    alive: true,
    pending_cancellation: false,
    prorated_discount_price_cents: 0,
    discount: null,
    option_discounts: {},
    end_time_of_subscription: "2099-01-01T00:00:00Z",
    successful_purchases_count: 2,
    remaining_charges_count: null,
    is_in_free_trial: false,
    is_test: false,
    is_overdue_for_charge: false,
    payment_method_update_required: false,
    payment_method_confirmation_pending: false,
    is_gift: false,
    is_installment_plan: false,
    current_recurrence_available: true,
  },
  contact_info: {
    email: "buyer@example.com",
    full_name: "Buyer",
    street: "",
    city: "",
    state: "",
    zip: "10001",
    country: "US",
  },
  countries: { US: "United States" },
  us_states: [],
  ca_provinces: [],
  used_card: null,
  used_paypal: { visual: "paypal-buyer@example.com", usable: true },
  recaptcha_key: null,
  paypal_client_id: "paypal-client-id",
  request_apple_pay_merchant_tokens: false,
  ...overrides,
});

const InertiaHost = () => {
  const [, rerender] = React.useReducer((count: number) => count + 1, 0);
  inertia.rerender = rerender;
  return <SubscriptionsManage key={inertia.key} />;
};

const renderManage = (props: Record<string, unknown>) => {
  inertia.props = props;
  inertia.serverProps = props;
  inertia.key = 0;
  return render(
    <LoggedInUserProvider value={null}>
      <InertiaHost />
    </LoggedInUserProvider>,
  );
};

const subscription = (overrides: Record<string, unknown> = {}) => ({ ...pageProps().subscription, ...overrides });
const giftSubscription = subscription({ is_gift: true, successful_purchases_count: 1 });
const savedCard = { type: "visa", number: "**** 4242", expiration_date: "12/30", requires_mandate: false };
const giftWarning = /Add your own payment method below to ensure that your membership renews/u;
const unavailableWarning = () => screen.queryByText(/It can't be used for this membership anymore/u);
const savedPayPalRadio = () => screen.queryByRole("radio", { name: /^PayPal · /u });

const submitUpdate = async () => {
  const update = await screen.findByRole("button", { name: "Update membership" });
  await waitFor(() => expect(update).toHaveProperty("disabled", false));
  fireEvent.click(update);
};

describe("SubscriptionsManage saved payment method", () => {
  beforeEach(() => mocks.updateSubscription.mockReset());
  afterEach(cleanup);

  it("opens on the saved PayPal account, labelled with its payer email", () => {
    renderManage(pageProps());

    expect(screen.getByRole("radio", { name: "PayPal · paypal-buyer@example.com" })).toHaveProperty("checked", true);
    expect(screen.getByRole("radio", { name: "Card" })).toHaveProperty("checked", false);
    expect(screen.queryByText(/Your saved payment method is PayPal/u)).toBeNull();
  });

  it("labels the saved PayPal account without an email when none is on file", () => {
    renderManage(pageProps({ used_paypal: { visual: "", usable: true } }));

    expect(screen.getByRole("radio", { name: "PayPal · saved account" })).toHaveProperty("checked", true);
  });

  it("keeps the saved PayPal account when the buyer updates without choosing another method", async () => {
    mocks.updateSubscription.mockResolvedValue({
      type: "done",
      message: "Your membership has been updated.",
      next: null,
    });
    renderManage(pageProps());

    await submitUpdate();

    await waitFor(() =>
      expect(mocks.updateSubscription).toHaveBeenCalledWith(expect.objectContaining({ cardParams: null })),
    );
  });

  it.each([
    ["cancelled", { alive: false }],
    ["pending cancellation", { alive: false, pending_cancellation: true }],
    ["fully charged", { remaining_charges_count: 0 }],
  ])("shows the same saved PayPal label for a %s membership", (_state, overrides) => {
    renderManage(pageProps({ subscription: subscription(overrides) }));

    expect(screen.getByRole("radio", { name: "PayPal · paypal-buyer@example.com" })).toHaveProperty("checked", true);
  });

  it("names a PayPal account the seller can no longer charge and opens on the card fields instead", async () => {
    renderManage(pageProps({ used_paypal: { visual: "paypal-buyer@example.com", usable: false } }));

    expect(unavailableWarning()?.textContent).toBe(
      "Your saved payment method is PayPal (paypal-buyer@example.com). It can't be used for this membership anymore, so choose a new payment method below.",
    );
    expect(savedPayPalRadio()).toBeNull();
    expect(await screen.findByRole("radio", { name: "Card" })).toHaveProperty("checked", true);
  });

  it("shows no saved PayPal for a card or for no saved payment method", () => {
    renderManage(pageProps({ used_paypal: null, used_card: savedCard }));
    expect(savedPayPalRadio()).toBeNull();
    expect(screen.getByLabelText("Saved credit card").textContent).toBe("**** 4242");
    cleanup();

    renderManage(pageProps({ used_paypal: null }));
    expect(savedPayPalRadio()).toBeNull();
    expect(screen.queryByText(giftWarning)).toBeNull();
  });

  it("shows the card the membership renews on after switching from the saved PayPal account", async () => {
    renderManage(pageProps());
    mocks.updateSubscription.mockImplementation(() => {
      inertia.serverProps = pageProps({ used_card: savedCard, used_paypal: null });
      return Promise.resolve({ type: "done", message: "Your membership has been updated.", next: null });
    });

    fireEvent.click(screen.getByRole("radio", { name: "Card" }));
    await submitUpdate();

    await waitFor(() => expect(screen.getByLabelText("Saved credit card").textContent).toBe("**** 4242"));
    expect(mocks.updateSubscription).toHaveBeenCalledWith(
      expect.objectContaining({ cardParams: mocks.newCard.cardParamsResult.cardParams }),
    );
    expect(screen.getByRole("radio", { name: "Card" })).toHaveProperty("checked", true);
    expect(savedPayPalRadio()).toBeNull();
  });

  describe("for a gift", () => {
    it("does not ask the recipient to add a payment method when their own PayPal account is saved", () => {
      renderManage(pageProps({ subscription: giftSubscription }));

      expect(savedPayPalRadio()).not.toBeNull();
      expect(screen.queryByText(giftWarning)).toBeNull();
    });

    it("still asks for a payment method when the saved PayPal account can't be charged", () => {
      renderManage(
        pageProps({
          subscription: giftSubscription,
          used_paypal: { visual: "paypal-buyer@example.com", usable: false },
        }),
      );

      expect(screen.getByText(giftWarning)).toBeTruthy();
    });

    it("asks for a payment method when none is saved and not when a card is", () => {
      renderManage(pageProps({ subscription: giftSubscription, used_paypal: null }));
      expect(screen.getByText(giftWarning)).toBeTruthy();
      cleanup();

      renderManage(pageProps({ subscription: giftSubscription, used_paypal: null, used_card: savedCard }));
      expect(screen.queryByText(giftWarning)).toBeNull();
    });

    it("drops the warning once the recipient's update saves a card", async () => {
      renderManage(pageProps({ subscription: giftSubscription, used_paypal: null }));
      expect(screen.getByText(giftWarning)).toBeTruthy();
      mocks.updateSubscription.mockImplementation(() => {
        inertia.serverProps = pageProps({ subscription: giftSubscription, used_paypal: null, used_card: savedCard });
        return Promise.resolve({ type: "done", message: "Your membership has been updated.", next: null });
      });

      await submitUpdate();

      await waitFor(() => expect(inertia.visit).toHaveBeenCalled());
      await waitFor(() => expect(screen.queryByText(giftWarning)).toBeNull());
    });

    it("selects the saved PayPal account and drops the warning once the reload brings it in", () => {
      renderManage(pageProps({ subscription: giftSubscription, used_paypal: null }));
      expect(screen.getByText(giftWarning)).toBeTruthy();

      // What Manage's post-update reload delivers after a PayPal approval.
      inertia.serverProps = pageProps({ subscription: giftSubscription });
      act(() => inertia.visit(window.location.href));

      expect(screen.getByRole("radio", { name: "PayPal · paypal-buyer@example.com" })).toHaveProperty("checked", true);
      expect(screen.queryByText(giftWarning)).toBeNull();
    });
  });
});
