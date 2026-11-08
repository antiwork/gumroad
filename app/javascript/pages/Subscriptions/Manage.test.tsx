// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { getReusablePaymentMethodResult } from "$app/data/payment_method_result";
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

  it("offers the payment method fields while this period is free but the renewal is paid", () => {
    const free = { ...pageProps().subscription, price: 0, pre_discount_price: 500 };
    renderManage(pageProps({ subscription: free, used_card: savedCard, used_paypal: null }));
    expect(screen.queryByLabelText("Saved credit card")).toBeNull();
    cleanup();

    renderManage(
      pageProps({ subscription: { ...free, next_charge_price: 500 }, used_card: savedCard, used_paypal: null }),
    );
    expect(screen.getByLabelText("Saved credit card").textContent).toBe("**** 4242");
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
    // The saved PayPal account is gone, so the radio rows only appear once the PayPal SDK has
    // decided whether PayPal is still available (usePayPalImplementation loads it in an effect).
    // Asserting synchronously here races that load.
    expect(await screen.findByRole("radio", { name: "Card" })).toHaveProperty("checked", true);
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

describe("SubscriptionsManage current plan status", () => {
  afterEach(cleanup);

  const tieredProps = (overrides: Record<string, unknown>) =>
    pageProps({
      product: {
        ...pageProps().product,
        is_tiered_membership: true,
        options: [
          {
            id: "option-1",
            name: "Tier",
            quantity_left: null,
            description: null,
            price_difference_cents: null,
            recurrence_price_values: { monthly: { price_cents: 500, suggested_price_cents: null } },
            is_pwyw: false,
            duration_in_minutes: null,
          },
        ],
      },
      subscription: subscription({ option_id: "option-1", ...overrides }),
    });

  it("states the next charge instead of promising that a free current price will remain", () => {
    renderManage(tieredProps({ price: 0, pre_discount_price: 0, next_charge_price: 500 }));
    expect(screen.queryByText(/based on previous pricing\. Your next charge will be \$5\./u)).not.toBeNull();
    expect(screen.queryByText(/will remain the same/u)).toBeNull();
  });

  it("keeps the previous-pricing promise when the next charge stays at the current price", () => {
    renderManage(tieredProps({ price: 300, pre_discount_price: 300, next_charge_price: 300 }));
    expect(
      screen.queryByText(
        /based on previous pricing\. This price will remain the same when updating your payment method\./u,
      ),
    ).not.toBeNull();
  });
});

describe("SubscriptionsManage pay-what-you-want hint", () => {
  afterEach(cleanup);

  const pwywProps = (discount: Record<string, unknown>) =>
    pageProps({
      product: {
        ...pageProps().product,
        is_tiered_membership: true,
        price_cents: 0,
        recurrences: [{ id: "price-monthly", recurrence: "monthly", price_cents: 2400 }],
        options: [
          {
            id: "option-1",
            name: "Tier",
            quantity_left: null,
            description: null,
            price_difference_cents: null,
            recurrence_price_values: { monthly: { price_cents: 2400, suggested_price_cents: 2400 } },
            is_pwyw: true,
            duration_in_minutes: null,
          },
        ],
      },
      subscription: subscription({
        option_id: "option-1",
        price: 1680,
        pre_discount_price: 2400,
        discount,
        option_discounts: { "option-1": discount },
      }),
    });

  it("offers the payment method fields to an unchanged pay-what-you-want plan that is free now but paid at renewal", () => {
    const props = pwywProps({
      type: "percent",
      percents: 100,
      product_ids: null,
      expires_at: null,
      minimum_quantity: null,
      duration_in_billing_cycles: null,
      minimum_amount_cents: null,
    });
    renderManage({
      ...props,
      subscription: { ...props.subscription, price: 0, next_charge_price: 2400 },
      used_card: savedCard,
      used_paypal: null,
    });
    expect(screen.getByLabelText("Saved credit card").textContent).toBe("**** 4242");
  });

  const pwywInput = () => {
    const inputs = screen
      .getAllByLabelText("Name a fair price:")
      .filter((element): element is HTMLInputElement => element instanceof HTMLInputElement);
    const input = inputs.at(0);
    if (inputs.length !== 1 || !input) throw new Error(`expected one amount input, found ${inputs.length}`);
    return input;
  };

  it("hints the amount after a percent code, which is what the subscriber pays", () => {
    renderManage(
      pwywProps({
        type: "percent",
        percents: 30,
        product_ids: null,
        expires_at: null,
        minimum_quantity: null,
        duration_in_billing_cycles: null,
        minimum_amount_cents: null,
      }),
    );

    expect(pwywInput().getAttribute("placeholder")).toBe("16.80+");
  });

  it("hints the full amount for a once-per-cart amount, which the cart subtracts", () => {
    renderManage(
      pwywProps({
        type: "fixed",
        cents: 720,
        once_per_cart: true,
        once_per_cart_amount_cents: 720,
        product_ids: null,
        expires_at: null,
        minimum_quantity: null,
        duration_in_billing_cycles: null,
        minimum_amount_cents: null,
      }),
    );

    expect(pwywInput().getAttribute("placeholder")).toBe("24+");
  });

  it("drops the code from the hint when fewer seats no longer meet its minimum", () => {
    const discount = {
      type: "percent",
      percents: 30,
      product_ids: null,
      expires_at: null,
      minimum_quantity: 2,
      duration_in_billing_cycles: null,
      minimum_amount_cents: null,
    };
    const props = pwywProps(discount);
    renderManage({
      ...props,
      product: {
        ...props.product,
        is_multiseat_license: true,
        recurrences: [{ id: "price-monthly", recurrence: "monthly", price_cents: 1000 }],
        options: [
          {
            id: "option-1",
            name: "Tier",
            quantity_left: null,
            description: null,
            price_difference_cents: null,
            recurrence_price_values: { monthly: { price_cents: 1000, suggested_price_cents: 2400 } },
            is_pwyw: true,
            duration_in_minutes: null,
          },
        ],
      },
      subscription: { ...props.subscription, quantity: 2 },
    });
    expect(pwywInput().getAttribute("placeholder")).toBe("16.80+");

    fireEvent.change(screen.getByLabelText("Seats"), { target: { value: "1" } });

    expect(pwywInput().getAttribute("placeholder")).toBe("24+");
  });
});

describe("SubscriptionsManage selected plan for a new card's future charges", () => {
  beforeEach(() => {
    mocks.updateSubscription.mockReset();
    mocks.updateSubscription.mockResolvedValue({
      type: "done",
      message: "Your membership has been updated.",
      next: null,
    });
    vi.mocked(getReusablePaymentMethodResult).mockClear();
  });
  afterEach(cleanup);

  const tier = (id: string, name: string, monthly: number, yearly: number) => ({
    id,
    name,
    quantity_left: null,
    description: null,
    price_difference_cents: null,
    recurrence_price_values: {
      monthly: { price_cents: monthly, suggested_price_cents: null },
      yearly: { price_cents: yearly, suggested_price_cents: null },
    },
    is_pwyw: false,
    duration_in_minutes: null,
  });

  const tieredProps = (gold: { monthly: number; yearly: number }) =>
    pageProps({
      product: {
        ...pageProps().product,
        is_tiered_membership: true,
        price_cents: 0,
        recurrences: [
          { id: "price-monthly", recurrence: "monthly", price_cents: 0 },
          { id: "price-yearly", recurrence: "yearly", price_cents: 0 },
        ],
        options: [
          tier("tier-silver", "Silver", 500, 5000),
          tier("tier-gold", "Gold", gold.monthly, gold.yearly),
          tier("tier-bronze", "Bronze", gold.monthly, gold.yearly),
        ],
      },
      subscription: subscription({ option_id: "tier-silver" }),
      used_paypal: null,
    });

  const preparedPlan = () => {
    const call = vi.mocked(getReusablePaymentMethodResult).mock.lastCall;
    return call?.[1].products[0]?.subscriptionPlan;
  };

  it("prepares the card with the tier and billing period the buyer picked", async () => {
    renderManage(tieredProps({ monthly: 900, yearly: 9000 }));

    fireEvent.click(screen.getByRole("radio", { name: "Gold" }));
    fireEvent.change(screen.getByLabelText("Recurrence"), { target: { value: "yearly" } });
    await submitUpdate();

    await waitFor(() => expect(mocks.updateSubscription).toHaveBeenCalledTimes(1));
    expect(getReusablePaymentMethodResult).toHaveBeenCalledTimes(1);
    expect(preparedPlan()).toEqual({
      variants: ["tier-gold"],
      price_id: "price-yearly",
      quantity: 1,
      price_range: undefined,
      perceived_price_cents: 9000,
    });
    expect(mocks.updateSubscription).toHaveBeenCalledWith(expect.objectContaining(preparedPlan()));
  });

  it("prepares the card with the last tier picked when it costs the same as the one picked before", async () => {
    renderManage(tieredProps({ monthly: 900, yearly: 9000 }));

    fireEvent.click(screen.getByRole("radio", { name: "Gold" }));
    fireEvent.click(screen.getByRole("radio", { name: "Bronze" }));
    await submitUpdate();

    await waitFor(() => expect(mocks.updateSubscription).toHaveBeenCalledTimes(1));
    expect(getReusablePaymentMethodResult).toHaveBeenCalledTimes(1);
    expect(preparedPlan()).toEqual({
      variants: ["tier-bronze"],
      price_id: "price-monthly",
      quantity: 1,
      price_range: undefined,
      perceived_price_cents: 900,
    });
    expect(mocks.updateSubscription).toHaveBeenCalledWith(expect.objectContaining(preparedPlan()));
  });
});
