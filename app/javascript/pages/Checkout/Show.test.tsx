// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { type SurchargesResponse } from "$app/data/customer_surcharge";
import CheckoutPage from "$app/pages/Checkout/Show";
import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";

import { type CartState } from "$app/components/Checkout/cartState";
import { type CheckoutPaymentConfig, useState } from "$app/components/Checkout/payment";

const mocks = vi.hoisted(() => {
  const props: Record<string, unknown> = {};
  return { props, surcharges: vi.fn(), order: vi.fn(), clientOrder: vi.fn(), analytics: vi.fn() };
});
vi.mock("$app/data/customer_surcharge", () => ({ getSurcharges: mocks.surcharges }));
vi.mock("$app/data/order", () => ({
  startOrderCreation: mocks.order,
  startClientConfirmOrderCreation: mocks.clientOrder,
  PaymentConfirmedError: class extends Error {},
}));
vi.mock("$app/data/user_action_event", () => ({
  trackUserActionEvent: mocks.analytics,
  trackUserProductAction: vi.fn(),
  getPlugins: () => "",
}));
vi.mock("$app/utils/user_analytics", () => ({ startTrackingForSeller: vi.fn(), trackProductEvent: vi.fn() }));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));
vi.mock("$app/components/useAddThirdPartyAnalytics", () => ({ useAddThirdPartyAnalytics: () => vi.fn() }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/Checkout/Receipt", () => ({ Receipt: () => null }));
vi.mock("$app/components/Checkout/TemporaryLibrary", () => ({ TemporaryLibrary: () => null }));
vi.mock("$app/components/Checkout/CrossSellModal", () => ({ CrossSellModal: () => null }));
vi.mock("$app/components/Checkout/UpsellModal", () => ({ UpsellModal: () => null }));
vi.mock("$app/components/Modal", () => ({ Modal: () => null }));
vi.mock("$app/components/Product/ConfigurationSelector", () => ({ computeOptionPrice: vi.fn() }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("@inertiajs/react", () => ({
  Head: () => null,
  router: { reload: vi.fn(), replace: vi.fn() },
  usePage: () => ({ props: mocks.props }),
  useForm: (initial: { cart: CartState }) => {
    const [data, setData] = React.useState(initial);
    return { data, setData, patch: vi.fn(), cancel: vi.fn() };
  },
}));
// Replace only collection of payment credentials. Show's real pay(), reducer, quote fetch,
// and choice of order endpoint remain in the test; no processor or payment is contacted.
vi.mock("$app/components/Checkout", () => ({
  Checkout: () => {
    const [state, dispatch] = useState();
    React.useEffect(() => {
      if (state.status.type === "validating") dispatch({ type: "start-payment" });
      if (state.status.type === "starting")
        dispatch({
          type: "set-payment-method",
          paymentMethod:
            state.checkoutPayment.integration === "payment_element_client_confirm"
              ? {
                  type: "payment-element-client-confirm",
                  confirmationTokenId: "ct_test",
                  selectedMethodType: "card",
                  cardCountry: "US",
                  walletType: null,
                  mountCurrency: "cad",
                  methodListToken: null,
                }
              : { type: "saved" },
        });
      if (state.status.type === "captcha") dispatch({ type: "set-recaptcha-response", recaptchaResponse: "test" });
    }, [state.status]);
    return (
      <>
        <button
          disabled={state.surcharges.type !== "loaded" || state.status.type !== "input"}
          onClick={() => dispatch({ type: "validate" })}
        >
          Pay
        </button>
        <output>
          {state.surcharges.type === "loaded"
            ? state.surcharges.result.buyer_currency_quote?.presentment_total_cents
            : "Updating"}
        </output>
        <p>{state.warning}</p>
      </>
    );
  },
}));

const quote = (expiresAt: string, amount = 1400): SurchargesResponse => ({
  vat_id_valid: false,
  has_vat_id_input: false,
  shipping_rate_cents: 0,
  tax_cents: 0,
  tax_included_cents: 0,
  subtotal: 1000,
  buyer_currency_quote: {
    token: `quote-${amount}`,
    currency: "cad",
    canonical_total_cents: 1000,
    presentment_total_cents: amount,
    rate: amount / 1000,
    subunit_to_unit: 100,
    expires_at: expiresAt,
    line_allocations: [
      {
        permalink: "test-product",
        price_cents: amount,
        tip_cents: 0,
        tax_cents: 0,
        shipping_cents: 0,
        total_cents: amount,
      },
    ],
  },
});

const config = (client: boolean): CheckoutPaymentConfig => {
  const shared = {
    fallback_reason: null,
    disable_wallets: true,
    request_apple_pay_merchant_tokens: false,
    payment_element_wallets: false,
    flat_payment_methods: true,
  };
  const options = {
    stripe_elements_mode: "payment" as const,
    currency: "usd" as const,
    buyer_currency_presentment: true,
    payment_method_types: ["card"],
    stripe_link_enabled: false,
  };
  return client
    ? {
        ...shared,
        integration: "payment_element_client_confirm",
        recurring_upi_registration: false,
        elements_options: {
          ...options,
          presentment_amount_cents: null,
          listed_currency_display: null,
          payment_method_list_token: null,
          stripe_connect_account_id: null,
        },
      }
    : {
        ...shared,
        integration: "payment_element",
        elements_options: { ...options, payment_method_creation: "manual" },
      };
};

beforeEach(() => {
  vi.stubGlobal("SSR", false);
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-09-08T12:00:00Z"));
  vi.stubGlobal("Routes", { checkout_path: () => "/checkout" });
  mocks.analytics.mockResolvedValue(undefined);
  mocks.order.mockImplementation(() => new Promise(() => {}));
  mocks.clientOrder.mockImplementation(() => new Promise(() => {}));
  const item = {
    ...PLACEHOLDER_CART_ITEM,
    price: 1000,
    product: {
      ...PLACEHOLDER_CART_ITEM.product,
      id: "product",
      permalink: "test-product",
      price_cents: 1000,
      has_tipping_enabled: false,
    },
  };
  mocks.props = {
    cart: { items: [item], email: "buyer@example.com", discountCodes: [], rejectPppDiscount: false },
    stripe_fonts_css_source: "",
    checkout: {
      add_products: [],
      address: { street: "", city: "", zip: "10001" },
      ca_provinces: [],
      cart_save_debounce_ms: 1000,
      clear_cart: false,
      countries: { US: "United States" },
      country: "US",
      default_tip_option: 0,
      discover_url: "https://example.com",
      gift: null,
      max_allowed_cart_products: 50,
      paypal_client_id: "",
      recaptcha_key: null,
      recaptcha_score_based: false,
      recaptcha_challenge_key: null,
      saved_credit_card: null,
      state: "NY",
      tip_options: [],
      us_states: ["NY"],
    },
  };
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.resetAllMocks();
});

describe.each([false, true])("checkout expired quote (client-confirm=%s)", (client) => {
  it("refreshes before order creation and only submits the changed quote after another buyer click", async () => {
    mocks.props.checkout_payment = config(client);
    mocks.surcharges
      .mockResolvedValueOnce(quote("2026-09-08T12:00:01Z"))
      .mockResolvedValue(quote("2999-01-01T00:00:00Z", 1500));
    render(<CheckoutPage />);
    await act(() => vi.advanceTimersByTimeAsync(400));
    expect(screen.getByText("1400")).toBeTruthy();
    vi.setSystemTime(new Date("2026-09-08T12:00:02Z"));
    fireEvent.click(screen.getByRole("button", { name: "Pay" }));
    await act(() => vi.advanceTimersByTimeAsync(400));
    expect(mocks.order).not.toHaveBeenCalled();
    expect(mocks.clientOrder).not.toHaveBeenCalled();
    expect(screen.getByText("1500")).toBeTruthy();
    expect(screen.getByText(/Please review the updated total/u)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Pay" }));
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(client ? mocks.clientOrder : mocks.order).toHaveBeenCalledOnce();
    expect((client ? mocks.clientOrder : mocks.order).mock.calls[0]?.[0].buyerCurrencyQuote).toBe("quote-1500");
    expect(client ? mocks.order : mocks.clientOrder).not.toHaveBeenCalled();
  });

  it("rechecks expiry after awaited analytics before either order consumer", async () => {
    mocks.props.checkout_payment = config(client);
    mocks.surcharges
      .mockResolvedValueOnce(quote("2026-09-08T12:00:01Z"))
      .mockResolvedValue(quote("2999-01-01T00:00:00Z", 1500));
    let finishAnalytics: (() => void) | undefined;
    mocks.analytics.mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          finishAnalytics = resolve;
        }),
    );
    render(<CheckoutPage />);
    await act(() => vi.advanceTimersByTimeAsync(400));
    fireEvent.click(screen.getByRole("button", { name: "Pay" }));
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(finishAnalytics).toBeTypeOf("function");
    vi.setSystemTime(new Date("2026-09-08T12:00:02Z"));
    await act(async () => finishAnalytics?.());
    await act(() => vi.advanceTimersByTimeAsync(400));
    expect(mocks.order).not.toHaveBeenCalled();
    expect(mocks.clientOrder).not.toHaveBeenCalled();
    expect(screen.getByText("1500")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Pay" }).hasAttribute("disabled")).toBe(false);
  });
});
