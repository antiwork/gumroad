// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import type { OfferCodeResponseData } from "$app/data/offer_code";
import CheckoutPage from "$app/pages/Checkout/Show";
import type { Discount } from "$app/parsers/checkout";
import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";
import { cast } from "$app/utils/cast";

import type { CartSaveCallbacks } from "$app/components/Checkout/checkoutPaymentRefresh";
import { type CheckoutPaymentConfig, useState } from "$app/components/Checkout/payment";

type CartSaveVisit = CartSaveCallbacks & { onStart?: () => void };

// Real Show and real Checkout, so their effects run in React's own parent/child order.
const mocks = vi.hoisted<{
  props: Record<string, unknown>;
  saveVisits: unknown[];
  quotes: { code: string; resolve: (response: unknown) => void }[];
  statuses: string[];
}>(() => ({ props: {}, saveVisits: [], quotes: [], statuses: [] }));
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
vi.mock("$app/data/offer_code", () => ({
  computeOfferDiscount: vi.fn(
    ({ code }: { code: string }) => new Promise((resolve) => mocks.quotes.push({ code, resolve })),
  ),
}));
vi.mock("$app/data/order", () => ({
  startOrderCreation: vi.fn(() => new Promise(() => {})),
  startClientConfirmOrderCreation: vi.fn(() => new Promise(() => {})),
  PaymentConfirmedError: class extends Error {},
}));
vi.mock("$app/data/user_action_event", () => ({
  trackUserActionEvent: vi.fn(() => Promise.resolve()),
  trackUserProductAction: vi.fn(),
  getPlugins: () => "",
}));
vi.mock("$app/utils/user_analytics", () => ({
  startTrackingForSeller: vi.fn(),
  trackProductEvent: vi.fn(),
  trackUserProductAction: vi.fn(),
}));
vi.mock("$app/utils/stripe_loader", () => ({ getCheckoutStripeInstance: vi.fn(), getStripeInstance: vi.fn() }));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));
vi.mock("$app/components/useAddThirdPartyAnalytics", () => ({ useAddThirdPartyAnalytics: () => vi.fn() }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/useOriginalLocation", () => ({ useOriginalLocation: () => "https://gumroad.com/checkout" }));
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => null }));
vi.mock("$app/components/Checkout/Receipt", () => ({ Receipt: () => null }));
vi.mock("$app/components/Checkout/TemporaryLibrary", () => ({ TemporaryLibrary: () => null }));
vi.mock("$app/components/Checkout/UpsellModal", () => ({ UpsellModal: () => null }));
vi.mock("$app/components/Checkout/CrossSellModal", () => ({
  CrossSellModal: ({ accept }: { accept: () => void }) => <button onClick={accept}>Accept offer</button>,
}));
vi.mock("$app/components/Modal", () => ({
  Modal: ({ open, children }: { open: boolean; children?: React.ReactNode }) => (open ? <div>{children}</div> : null),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn(), dismissAlert: vi.fn() }));
vi.mock("$app/components/Checkout/PaymentForm", () => ({
  PaymentForm: () => {
    const [state, dispatch] = useState();
    React.useEffect(() => void mocks.statuses.push(state.status.type), [state.status.type]);
    return (
      <>
        <button onClick={() => dispatch({ type: "offer" })}>Pay</button>
        <output aria-label="status">{state.status.type}</output>
      </>
    );
  },
}));
vi.mock("@inertiajs/react", () => ({
  Head: () => null,
  router: { reload: vi.fn(), replace: vi.fn() },
  usePage: () => ({ props: mocks.props }),
  useForm: (initial: unknown) => {
    const [data, setData] = React.useState(initial);
    const patch = vi.fn((_url: string, visit: unknown) => void mocks.saveVisits.push(visit));
    return { data, setData, patch, cancel: vi.fn() };
  },
}));

const paymentConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  disable_wallets: true,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: false,
  flat_payment_methods: true,
  elements_options: {
    stripe_elements_mode: "payment",
    currency: "usd",
    buyer_currency_presentment: true,
    payment_method_types: ["card"],
    stripe_link_enabled: false,
    payment_method_creation: "manual",
  },
};

const product = (id: string, crossSells: unknown[] = []) => ({
  ...PLACEHOLDER_CART_ITEM.product,
  id,
  permalink: id,
  name: id,
  creator: { ...PLACEHOLDER_CART_ITEM.product.creator, id: "seller" },
  price_cents: 1000,
  has_tipping_enabled: false,
  cross_sells: cast<typeof PLACEHOLDER_CART_ITEM.product.cross_sells>(crossSells),
});

beforeEach(() => {
  vi.stubGlobal("SSR", false);
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-09-08T12:00:00Z"));
  vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "/checkout" }));
  const crossSell = {
    id: "cross-sell",
    replace_selected_products: false,
    text: "Add Q",
    description: "",
    discount: null,
    ratings: null,
    offered_product: {
      product: product("q"),
      recurrence: null,
      price: 1000,
      option_id: null,
      rent: false,
      quantity: 1,
      affiliate_id: null,
      recommended_by: null,
      call_start_time: null,
      accepted_offer: null,
      pay_in_installments: false,
      force_new_subscription: false,
    },
  };
  mocks.props = {
    cart: {
      items: [{ ...PLACEHOLDER_CART_ITEM, price: 1000, product: product("p", [crossSell]) }],
      email: "buyer@example.com",
      // A default the saved cart did not meet yet.
      discountCodes: [{ code: "BULK50", products: {}, fromUrl: true }],
      rejectPppDiscount: false,
    },
    checkout_payment: paymentConfig,
    stripe_fonts_css_source: "",
    checkout: {
      add_products: [],
      address: { street: "", city: "", zip: "10001" },
      ca_provinces: [],
      cart_save_debounce_ms: 1000,
      clear_cart: false,
      countries: { US: "United States" },
      country: "US",
      default_offer_codes: [],
      existing_customer_default_offer_code_valid: false,
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
  mocks.saveVisits.length = 0;
  mocks.quotes.length = 0;
  mocks.statuses.length = 0;
  cleanup();
  vi.useRealTimers();
  vi.clearAllMocks();
});

const answer = async (response: OfferCodeResponseData) => {
  const quote = mocks.quotes.find(({ code }) => code === "BULK50");
  if (!quote) throw new Error("expected a BULK50 quote");
  await act(async () => {
    quote.resolve(response);
    await vi.advanceTimersByTimeAsync(1000);
  });
  // The quote's cart write, then the surcharge refetch the product update queues.
  await act(() => vi.advanceTimersByTimeAsync(1000));
};

const acceptOfferAndDeliverConfiguration = async () => {
  render(<CheckoutPage />);
  await act(() => vi.advanceTimersByTimeAsync(1000));
  fireEvent.click(screen.getByRole("button", { name: "Pay" }));
  await act(() => vi.advanceTimersByTimeAsync(0));
  fireEvent.click(screen.getByRole("button", { name: "Accept offer" }));
  await act(() => vi.advanceTimersByTimeAsync(1000));
  expect(mocks.quotes.map(({ code }) => code)).toEqual(["BULK50"]);
  const save = cast<CartSaveVisit>(mocks.saveVisits.at(-1));
  act(() => {
    save.onStart?.();
    save.onSuccess({ props: { checkout_payment: paymentConfig } });
    save.onFinish({});
  });
  await act(() => vi.advanceTimersByTimeAsync(1000));
  // Configuration and surcharges are back; the accepted offer still waits on the quote.
  expect(screen.getByLabelText("status").textContent).toBe("input");
};

it("resumes an accepted offer once the totals reflect the lines a quote wrote", async () => {
  await acceptOfferAndDeliverConfiguration();

  await answer({
    valid: true,
    products_data: {
      p: cast<Discount>({ type: "percent", percents: 50, product_ids: null, expires_at: null, minimum_quantity: null }),
    },
  });

  expect(screen.getByLabelText("status").textContent).toBe("validating");
  expect(mocks.statuses.filter((status) => status === "validating")).toHaveLength(1);
});

it("resumes an accepted offer once when the quote answers ineligible", async () => {
  await acceptOfferAndDeliverConfiguration();

  await answer({
    valid: false,
    error_code: "unmet_minimum_purchase_quantity",
    error_message: "Sorry, the discount code you wish to use has an unmet minimum quantity.",
  });

  expect(screen.getByLabelText("status").textContent).toBe("validating");
  expect(mocks.statuses.filter((status) => status === "validating")).toHaveLength(1);
});
