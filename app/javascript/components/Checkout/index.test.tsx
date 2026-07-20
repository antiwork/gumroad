// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { CartItem, CartState, Product as CartProduct } from "$app/components/Checkout/cartState";
import { Checkout } from "$app/components/Checkout/index";
import { StateContext, type CheckoutPaymentConfig, type State } from "$app/components/Checkout/payment";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

// Subtrees that talk to Stripe/network or need browser APIs irrelevant to the amounts
// being asserted.
vi.mock("$app/components/Checkout/PaymentForm", () => ({ PaymentForm: () => null }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
// Pulls in vendor analytics scripts ($vendor/facebook_pixel) that vitest cannot resolve.
vi.mock("$app/utils/user_analytics", () => ({ trackUserProductAction: vi.fn(), startTrackingForSeller: vi.fn() }));
// Needs the logged-in-user context (for lazy loading), irrelevant to the amounts asserted.
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => null }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://gumroad.com/checkout",
}));

const paymentElementConfig: CheckoutPaymentConfig = {
  integration: "payment_element",
  fallback_reason: null,
  disable_wallets: true,
  request_apple_pay_merchant_tokens: false,
  elements_options: {
    stripe_elements_mode: "payment",
    currency: "usd",
    buyer_currency_presentment: true,
    payment_method_types: ["card"],
    payment_method_creation: "manual",
  },
};

const cartProduct = (overrides: Partial<CartProduct> = {}): CartProduct => ({
  id: "product-id",
  permalink: "prod",
  name: "Product",
  creator: { id: "seller-a", name: "Seller A", profile_url: "#", avatar_url: "" },
  url: "#",
  thumbnail_url: null,
  currency_code: "usd",
  price_cents: 1_000,
  quantity_remaining: null,
  pwyw: null,
  installment_plan: null,
  is_preorder: false,
  is_tiered_membership: false,
  is_legacy_subscription: false,
  is_multiseat_license: false,
  is_quantity_enabled: false,
  free_trial: null,
  options: [],
  recurrences: null,
  duration_in_months: null,
  native_type: "digital",
  custom_fields: [],
  require_shipping: false,
  supports_paypal: null,
  has_offer_codes: false,
  has_tipping_enabled: false,
  analytics: { google_analytics_id: null, facebook_pixel_id: null, free_sale: false },
  exchange_rate: 1,
  rental: null,
  shippable_country_codes: [],
  ppp_details: null,
  upsell: null,
  cross_sells: [],
  archived: false,
  can_gift: false,
  bundle_products: [],
  ...overrides,
});

const cartItem = (overrides: Partial<CartItem> = {}): CartItem => ({
  product: cartProduct(),
  price: 1_000,
  quantity: 1,
  recurrence: null,
  option_id: null,
  recommended_by: null,
  affiliate_id: null,
  rent: false,
  url_parameters: {},
  referrer: "",
  recommender_model_name: null,
  call_start_time: null,
  pay_in_installments: false,
  force_new_subscription: false,
  ...overrides,
});

const stateProduct = (overrides: Partial<State["products"][number]> = {}): State["products"][number] => ({
  permalink: "prod",
  name: "Product",
  creator: { id: "seller-a", name: "Seller A", profile_url: "#", avatar_url: "" },
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

const buildState = (overrides: Partial<State> = {}): State => ({
  products: [stateProduct()],
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

const renderCheckout = (state: State, cart: CartState) =>
  render(
    <StateContext.Provider value={[state, vi.fn()]}>
      <Checkout discoverUrl="#" cart={cart} updateCart={vi.fn()} />
    </StateContext.Provider>,
  );

afterEach(cleanup);

describe("Checkout buyer-currency line amounts", () => {
  // The PR's odd-cent example: 334 + 667 cents at a 1.25 CAD rate. Rounding each line in
  // the browser renders CA$4.18 + CA$8.34 = CA$12.52 while the locked/charged total is
  // CA$12.51 and persistence records [417, 834]. The page must render the server's
  // allocation so the visible lines sum to — and match — what the buyer is charged.
  const oddCentState = () =>
    buildState({
      products: [stateProduct({ permalink: "first", price: 334 }), stateProduct({ permalink: "second", price: 667 })],
      surcharges: {
        type: "loaded",
        result: {
          vat_id_valid: false,
          has_vat_id_input: false,
          shipping_rate_cents: 0,
          tax_cents: 0,
          tax_included_cents: 0,
          subtotal: 1_001,
          buyer_currency_quote: {
            token: "quote-token",
            currency: "cad",
            canonical_total_cents: 1_001,
            presentment_total_cents: 1_251,
            rate: 1.25,
            subunit_to_unit: 100,
            expires_at: "2999-01-01T00:00:00Z",
            line_allocations: [
              { permalink: "first", price_cents: 417, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 417 },
              {
                permalink: "second",
                price_cents: 834,
                tip_cents: 0,
                tax_cents: 0,
                shipping_cents: 0,
                total_cents: 834,
              },
            ],
          },
        },
      },
    });

  const oddCentCart = (): CartState => ({
    items: [
      cartItem({ product: cartProduct({ id: "p1", permalink: "first", name: "First" }), price: 334 }),
      cartItem({ product: cartProduct({ id: "p2", permalink: "second", name: "Second" }), price: 667 }),
    ],
    discountCodes: [],
  });

  it("renders each line from the server allocation so the visible lines sum exactly to the locked total", () => {
    const { getAllByLabelText, getAllByText } = renderCheckout(oddCentState(), oddCentCart());

    const linePrices = getAllByLabelText("Price").map((node) => node.textContent);
    // Independent per-line rounding would render CA$4.18 for the first item — one cent
    // above what the receipt will show for it.
    expect(linePrices).toEqual(["CA$4.17", "CA$8.34"]);
    // Both the Subtotal and Total rows show the locked amount (this cart has no tax,
    // shipping, or tip), never the CA$12.52 the rounded lines would imply.
    expect(getAllByText("CA$12.51")).toHaveLength(2);
  });

  it("falls back to canonical currency when the allocation does not match the cart", () => {
    const cart = oddCentCart();
    // Simulate a stale surcharge response for a different cart shape: the allocation no
    // longer lines up, so the page must suppress both the local-currency display and token.
    const state = oddCentState();
    if (state.surcharges.type === "loaded" && state.surcharges.result.buyer_currency_quote?.line_allocations) {
      state.surcharges.result.buyer_currency_quote.line_allocations =
        state.surcharges.result.buyer_currency_quote.line_allocations.slice(0, 1);
    }

    const { getAllByLabelText } = renderCheckout(state, cart);

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$3.34", "US$6.67"]);
  });
});
