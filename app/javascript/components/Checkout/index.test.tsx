// @vitest-environment happy-dom
import { cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { SurchargesResponse } from "$app/data/customer_surcharge";

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
  payment_element_wallets: false,
  flat_payment_methods: true,
  elements_options: {
    stripe_elements_mode: "payment",
    currency: "usd",
    buyer_currency_presentment: true,
    payment_method_types: ["card"],
    payment_method_creation: "manual",
    stripe_link_enabled: true,
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
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: false },
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
      subtotal: 1_000,
      buyer_currency_quote: null,
    },
  },
  availablePaymentMethods: [],
  paymentMethod: "card",
  paymentElementType: "card",
  willSaveCard: false,
  usingSavedCard: false,
  savedCreditCard: null,
  checkoutPayment: paymentElementConfig,
  status: { type: "input", errors: new Set() },
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

const renderCheckout = (state: State, cart: CartState, dispatch = vi.fn()) =>
  render(
    <StateContext.Provider value={[state, dispatch]}>
      <Checkout discoverUrl="#" cart={cart} updateCart={vi.fn()} />
    </StateContext.Provider>,
  );

afterEach(cleanup);

describe("Checkout cart editing", () => {
  it("previews each option with its candidate cart-discount allocation", () => {
    const basicOption: CartProduct["options"][number] = {
      id: "basic",
      name: "Basic",
      quantity_left: null,
      description: "",
      price_difference_cents: 0,
      recurrence_price_values: null,
      is_pwyw: false,
      duration_in_minutes: null,
      upsell_offered_variant_id: null,
    };
    const premiumOption = { ...basicOption, id: "premium", name: "Premium", price_difference_cents: 1_000 };
    const firstProduct = cartProduct({
      id: "first-product",
      permalink: "first",
      name: "First",
      options: [basicOption, premiumOption],
      has_offer_codes: true,
    });
    const secondProduct = cartProduct({
      id: "second-product",
      permalink: "second",
      name: "Second",
      has_offer_codes: true,
    });
    const discount = {
      type: "fixed" as const,
      cents: 1_500,
      once_per_cart: true,
      once_per_cart_id: "cart-discount",
      once_per_cart_amount_cents: 1_500,
      product_ids: null,
      expires_at: null,
      minimum_quantity: null,
      duration_in_billing_cycles: null,
      minimum_amount_cents: null,
    };
    const cart: CartState = {
      items: [cartItem({ product: firstProduct, option_id: basicOption.id }), cartItem({ product: secondProduct })],
      discountCodes: [{ code: "SAVE", products: { first: discount, second: discount }, fromUrl: false }],
    };
    const state = buildState({
      products: [stateProduct({ permalink: "first", price: 0 }), stateProduct({ permalink: "second", price: 500 })],
      surcharges: {
        type: "loaded",
        result: {
          vat_id_valid: false,
          has_vat_id_input: false,
          shipping_rate_cents: 0,
          tax_cents: 0,
          tax_included_cents: 0,
          subtotal: 500,
          buyer_currency_quote: null,
        },
      },
    });

    const view = renderCheckout(state, cart);
    const [editButton] = view.getAllByText("Edit");
    if (!editButton) throw new Error("Expected an edit button");
    fireEvent.click(editButton);

    const premium = view.getByRole("radio", { name: "Premium" });
    expect(premium.textContent).toContain("$5");
    expect(premium.textContent).not.toContain("$10");
  });
});

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

  it("renders the signed current-charge amount for an installment checkout", () => {
    const state = buildState({
      products: [
        stateProduct({
          price: 1_000,
          payInInstallments: true,
          installmentPlan: { numberOfInstallments: 3 },
        }),
      ],
      surcharges: {
        type: "loaded",
        result: {
          vat_id_valid: false,
          has_vat_id_input: false,
          shipping_rate_cents: 0,
          tax_cents: 0,
          tax_included_cents: 0,
          subtotal: 1_000,
          buyer_currency_quote: {
            token: "quote-token",
            currency: "cad",
            canonical_total_cents: 1_000,
            presentment_total_cents: 1_250,
            charge_presentment_total_cents: 418,
            future_installments_presentment_total_cents: 832,
            rate: 1.25,
            subunit_to_unit: 100,
            expires_at: "2999-01-01T00:00:00Z",
            line_allocations: [
              {
                permalink: "prod",
                price_cents: 1_250,
                tip_cents: 0,
                tax_cents: 0,
                shipping_cents: 0,
                total_cents: 1_250,
              },
            ],
          },
        },
      },
    });
    const cart: CartState = {
      items: [
        cartItem({
          product: cartProduct({ installment_plan: { number_of_installments: 3 } }),
          pay_in_installments: true,
        }),
      ],
      discountCodes: [],
    };

    const { getByText } = renderCheckout(state, cart);

    expect(getByText("Payment today")).toBeTruthy();
    expect(getByText("CA$4.18")).toBeTruthy();
    expect(getByText("Future installments")).toBeTruthy();
    expect(getByText("CA$8.32")).toBeTruthy();
  });
});

describe("Checkout method-forced listed-currency amounts", () => {
  // A BRL product paid with Pix (the reported case): the Payment Element mounts in BRL and the
  // charge bills the listed R$49.90 directly, with no FX quote in the response. Before this
  // was fixed every row divided the listed price by the product's stored USD rate, so the
  // buyer saw a US$9.15 cart summary and was then charged R$49.90 by the sheet beside it.
  const brlProduct = () =>
    cartProduct({ id: "brl-product", permalink: "brl", name: "Curso", currency_code: "brl", exchange_rate: 5.45 });

  const listedCurrencyPayment = (): CheckoutPaymentConfig => ({
    integration: "payment_element_client_confirm",
    fallback_reason: null,
    recurring_upi_registration: false,
    disable_wallets: true,
    request_apple_pay_merchant_tokens: false,
    payment_element_wallets: false,
    flat_payment_methods: true,
    elements_options: {
      stripe_elements_mode: "payment",
      currency: "brl",
      presentment_amount_cents: 4_990,
      listed_currency_display: { currency: "brl", subunit_to_unit: 100 },
      payment_method_types: ["card", "pix"],
      payment_method_list_token: null,
      stripe_link_enabled: false,
      stripe_connect_account_id: null,
    },
  });

  // `getProducts` always converts cart prices to canonical USD before they land in checkout state
  // (`price: convertToUSD(item, price)`), so state carries 915 for a R$49.90 product at rate 5.45
  // while the cart item carries the listed 4 990. Using the realistic USD value here matters: the
  // percentage tip is computed off state, so a fixture holding listed units in state would hide a
  // tip that is displayed in the wrong currency.
  const brlState = (overrides: Partial<State> = {}): State =>
    buildState({
      products: [stateProduct({ permalink: "brl", price: 915 })],
      checkoutPayment: listedCurrencyPayment(),
      surcharges: {
        type: "loaded",
        result: {
          vat_id_valid: false,
          has_vat_id_input: false,
          shipping_rate_cents: 0,
          tax_cents: 0,
          tax_included_cents: 0,
          subtotal: 915,
          buyer_currency_quote: null,
        },
      },
      ...overrides,
    });

  const brlCart = (): CartState => ({
    items: [cartItem({ product: brlProduct(), price: 4_990 })],
    discountCodes: [],
  });

  it("renders the listed price the buyer is actually charged, not a USD conversion of it", () => {
    const { getAllByLabelText, getAllByText, queryByText } = renderCheckout(brlState(), brlCart());

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["R$49.90"]);
    // Subtotal and Total rows both show the listed amount, which is what the Stripe sheet
    // next to them and the charge itself use.
    expect(getAllByText("R$49.90")).toHaveLength(3);
    // The old rendering: 4990 / 5.45 ≈ 915 canonical cents, labelled US$.
    expect(queryByText("US$9.15")).toBeNull();
  });

  it("converts the USD-side tax and shipping rows at the product's stored rate", () => {
    // The surcharge endpoint answers in USD, and Charge::MethodForcedPresentment converts those
    // same two figures back with this same stored rate, so display and charge agree.
    const { getByText } = renderCheckout(
      brlState({
        surcharges: {
          type: "loaded",
          result: {
            vat_id_valid: false,
            has_vat_id_input: false,
            shipping_rate_cents: 545,
            tax_cents: 109,
            tax_included_cents: 0,
            subtotal: 4_990,
            buyer_currency_quote: null,
          },
        },
      }),
      brlCart(),
    );

    expect(getByText("R$5.94")).toBeTruthy();
    expect(getByText("R$29.70")).toBeTruthy();
    // 4990 + 594 + 2970
    expect(getByText("R$85.54")).toBeTruthy();
  });

  it("stays in canonical USD when the cart no longer matches the forced-currency lane", () => {
    // A second item means the server would no longer mount a forced-currency element, so the
    // listed-currency display must not be shown for a charge that will be canonical USD.
    const cart: CartState = {
      items: [
        cartItem({ product: brlProduct(), price: 4_990 }),
        cartItem({ product: cartProduct({ id: "second", permalink: "second", name: "Second" }), price: 1_000 }),
      ],
      discountCodes: [],
    };

    const { getAllByLabelText } = renderCheckout(
      brlState({ products: [stateProduct({ permalink: "brl", price: 915 }), stateProduct({ permalink: "second" })] }),
      cart,
    );

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$9.15", "US$10"]);
  });

  // The tip is canonical USD cents in state on every lane (`computeTip` takes its percentage of
  // `getTotalPriceFromProducts`, which holds converted USD), and the submission path converts it
  // into listed minor units. Displaying it verbatim under an R$ label therefore understates what
  // the buyer is about to be charged — a 20% tip on R$49.90 rendered as R$1.83 instead of R$9.98.
  const tippingProduct = () => ({ ...brlProduct(), has_tipping_enabled: true });

  const tippingCart = (): CartState => ({
    items: [cartItem({ product: tippingProduct(), price: 4_990 })],
    discountCodes: [],
  });

  it("shows the percentage tip the order actually submits, not a double-rounded conversion", () => {
    const { getAllByText, queryByText } = renderCheckout(
      brlState({
        products: [stateProduct({ permalink: "brl", price: 915, hasTippingEnabled: true })],
        tip: { type: "percentage", percentage: 20 },
      }),
      tippingCart(),
    );

    // The order submits 20% of the LISTED price: computeTipsForLines gets getDiscountedPrice(...) =
    // 4 990, so tip_cents is 998 and the charge bills R$9.98. Routing the display through the
    // canonical figure instead (20% of 915 = 183, then 183 * 5.45 = 997) shows R$9.97 — a centavo
    // under what is charged, which is the display/charge mismatch this change exists to remove.
    expect(getAllByText("R$9.98").length).toBeGreaterThan(0);
    expect(queryByText("R$9.97")).toBeNull();
    // The unconverted USD figure must not appear under an R$ label either.
    expect(queryByText("R$1.83")).toBeNull();
    // Total is the listed price plus that same tip: 4990 + 998.
    expect(getAllByText("R$59.88").length).toBeGreaterThan(0);
  });

  it("charges and shows the fixed tip exactly as the buyer typed it", () => {
    // The buyer typed R$54.53 into the tip box, so `listedAmount` holds 5 453 and `amount` holds
    // the canonical rounding of it. The lane bills the listed figure directly, so both the summary
    // and the charge are R$54.53 — no arithmetic between what was typed and what is billed.
    const { getAllByText, queryByText } = renderCheckout(
      brlState({
        products: [stateProduct({ permalink: "brl", price: 915, hasTippingEnabled: true })],
        tip: { type: "fixed", amount: 1_000, listedAmount: 5_453 },
      }),
      tippingCart(),
    );

    expect(getAllByText("R$54.53").length).toBeGreaterThan(0);
    // Converting the canonical figure at the stored rate lands three centavos under.
    expect(queryByText("R$54.50")).toBeNull();
    // Displaying the canonical figure verbatim under an R$ label would under-quote by the whole rate.
    expect(queryByText("R$10")).toBeNull();
    // 4990 + 5453
    expect(getAllByText("R$104.43").length).toBeGreaterThan(0);
  });

  it("shows the typed tip unchanged inside the custom-tip box", () => {
    // gumroad-private#1376: the box the buyer types into used to re-derive its own value from the
    // stored canonical cents, so typing R$10.00 redisplayed as R$9.97 and billed R$9.96 — the
    // buyer's own choice drifted underneath them. The typed amount is now what is kept and billed.
    const { getByLabelText, getAllByText, queryByText } = renderCheckout(
      brlState({
        products: [stateProduct({ permalink: "brl", price: 915, hasTippingEnabled: true })],
        tip: { type: "fixed", amount: 183, listedAmount: 1_000 },
      }),
      tippingCart(),
    );

    expect(getByLabelText("Tip").getAttribute("value")).toBe("10");
    expect(getAllByText("R$10").length).toBeGreaterThan(0);
    expect(queryByText("R$9.97")).toBeNull();
    expect(queryByText("R$9.96")).toBeNull();
  });

  it("keeps the listed currency while the save-card box is checked, because the checkbox does not change the charge", () => {
    // Unlike the FX-quoted lane, where saving a card reroutes the charge to the canonical path,
    // the client-confirm submit branch ignores the checkbox and the payload never carries
    // `save_card` — the ConfirmationToken still charges the listed amount. The checkbox defaults
    // to checked for logged-in buyers, so gating on it would re-show the wrong USD summary for
    // every logged-in buyer entering a new card.
    const { getAllByLabelText } = renderCheckout(brlState({ willSaveCard: true }), brlCart());

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["R$49.90"]);
  });

  it("hides the picker while checkout presents the listed currency", () => {
    const state = brlState();
    if (state.surcharges.type !== "loaded") throw new Error("Expected loaded surcharges");
    state.surcharges.result = {
      ...state.surcharges.result,
      detected_buyer_currency: "brl",
      available_buyer_currencies: [
        { code: "usd", label: "$ (US Dollars)" },
        { code: "eur", label: "€ (Euro)" },
      ],
    };

    const { queryByLabelText } = renderCheckout(state, brlCart());

    expect(queryByLabelText("Currency")).toBeNull();
  });

  it("stays in canonical USD while a saved card is selected, because that charge is not in the listed currency", () => {
    // Saved cards stay on the server-confirm path, which never reaches
    // Charge::MethodForcedPresentment — and `usingSavedCard` defaults true for any buyer with a
    // card on file, so this is the DEFAULT render for a returning buyer, not an edge case.
    const { getAllByLabelText } = renderCheckout(brlState({ usingSavedCard: true }), brlCart());

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$9.15"]);
  });

  it("stays in canonical USD while PayPal is selected", () => {
    // PayPal charges USD (or the merchant-account currency at PayPal's own rate), never the listed
    // price, so the summary must show the USD totals that charge will use.
    const { getAllByLabelText } = renderCheckout(brlState({ paymentMethod: "paypal" }), brlCart());

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$9.15"]);
  });

  it("stays in canonical USD when the loaded total falls below the Payment Element minimum", () => {
    // PaymentForm re-checks canUseStripePaymentElementClientConfirm after surcharges load: a
    // discount can drop the canonical total below Stripe's Payment Element minimum, at which
    // point the form falls back to the CardElement and charges canonical USD. The summary must
    // follow the same predicate, or it would show listed-currency totals for a USD charge.
    const { getAllByLabelText } = renderCheckout(
      brlState({
        products: [stateProduct({ permalink: "brl", price: 40 })],
        surcharges: {
          type: "loaded",
          result: {
            vat_id_valid: false,
            has_vat_id_input: false,
            shipping_rate_cents: 0,
            tax_cents: 0,
            tax_included_cents: 0,
            subtotal: 40,
            buyer_currency_quote: null,
          },
        },
      }),
      brlCart(),
    );

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$9.15"]);
  });

  it("stays in canonical USD when the buyer toggles pay-in-installments after the page rendered", () => {
    // `checkoutPayment` is an Inertia prop that does not refresh on cart edits, so the client has to
    // re-check this itself: the element silently drops to a canonical-USD CardElement.
    const cart: CartState = {
      items: [cartItem({ product: brlProduct(), price: 4_990, pay_in_installments: true })],
      discountCodes: [],
    };

    const { getAllByLabelText } = renderCheckout(brlState(), cart);

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$9.15"]);
  });

  it("defers to the FX-quoted lane when a quote is also usable, so only one lane is ever in effect", () => {
    // The two lanes are near-mutually-exclusive but not provably so: a non-USD buyer of a
    // non-USD-priced product can satisfy both. The quote's allocation is the one locked into the
    // token and verified at charge time, so it must win. Pinned here because the tip basis in
    // Show.tsx follows the same precedence — if display and submission ever disagreed about which
    // lane is in effect, the tip would be computed in one currency and rendered in the other.
    const { getAllByLabelText, queryByText } = renderCheckout(
      brlState({
        surcharges: {
          type: "loaded",
          result: {
            vat_id_valid: false,
            has_vat_id_input: false,
            shipping_rate_cents: 0,
            tax_cents: 0,
            tax_included_cents: 0,
            subtotal: 915,
            buyer_currency_quote: {
              token: "quote-token",
              currency: "cad",
              canonical_total_cents: 915,
              presentment_total_cents: 1_144,
              rate: 1.25,
              subunit_to_unit: 100,
              expires_at: "2126-07-01T00:00:00Z",
              line_allocations: [
                {
                  permalink: "brl",
                  price_cents: 1_144,
                  tip_cents: 0,
                  tax_cents: 0,
                  shipping_cents: 0,
                  total_cents: 1_144,
                },
              ],
            },
          },
        },
      }),
      brlCart(),
    );

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["CA$11.44"]);
    expect(queryByText("R$49.90")).toBeNull();
  });
});

describe("Checkout direct-listed currency picker", () => {
  const directListedPayment: CheckoutPaymentConfig = {
    integration: "payment_element_client_confirm",
    fallback_reason: null,
    recurring_upi_registration: false,
    disable_wallets: true,
    request_apple_pay_merchant_tokens: false,
    payment_element_wallets: false,
    flat_payment_methods: true,
    elements_options: {
      stripe_elements_mode: "payment",
      currency: "cad",
      presentment_amount_cents: 1_500,
      listed_currency_display: { currency: "cad", subunit_to_unit: 100 },
      direct_listed_card: true,
      payment_method_types: ["card"],
      payment_method_list_token: null,
      stripe_link_enabled: false,
      stripe_connect_account_id: null,
    },
  };
  const directListedSurcharges: SurchargesResponse = {
    vat_id_valid: false,
    has_vat_id_input: false,
    shipping_rate_cents: 0,
    tax_cents: 0,
    tax_included_cents: 0,
    subtotal: 1_000,
    detected_buyer_currency: "cad",
    available_buyer_currencies: [
      { code: "usd", label: "$ (US Dollars)" },
      { code: "cad", label: "CA$ (Canadian Dollars)" },
      { code: "gbp", label: "£ (British Pounds)" },
    ],
    buyer_currency_quote: null,
  };
  const directListedState = (overrides: Partial<State> = {}) =>
    buildState({
      checkoutPayment: directListedPayment,
      products: [stateProduct({ price: 1_000 })],
      surcharges: { type: "loaded", result: directListedSurcharges },
      ...overrides,
    });
  const directListedCart: CartState = {
    items: [
      cartItem({
        product: cartProduct({ currency_code: "cad", exchange_rate: 1.5 }),
        price: 1_500,
      }),
    ],
    discountCodes: [],
  };

  it("renders a USD and listed-currency control on the direct-listed card lane", () => {
    const dispatch = vi.fn();
    const { getAllByLabelText, getByLabelText } = renderCheckout(directListedState(), directListedCart, dispatch);
    const picker = getByLabelText("Currency");

    expect(Array.from(picker.querySelectorAll("option"), (option) => option.value)).toEqual(["usd", "cad"]);
    expect(picker).toHaveProperty("value", "cad");
    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["CA$15"]);

    fireEvent.change(picker, { target: { value: "usd" } });
    expect(dispatch).toHaveBeenCalledWith({ type: "set-value", buyerCurrency: "usd" });
  });

  it("stays on the listed currency when buyerCurrency is unset and GeoIP is not listed", () => {
    // The mount treats null buyerCurrency as listed (null !== "usd"). The picker used to prefer
    // detected / options[0], so a USD or GBP GeoIP painted USD next to a CAD total and CAD Element.
    const { getAllByLabelText, getByLabelText } = renderCheckout(
      directListedState({
        surcharges: {
          type: "loaded",
          result: { ...directListedSurcharges, detected_buyer_currency: "gbp" },
        },
      }),
      directListedCart,
    );

    expect(getByLabelText("Currency")).toHaveProperty("value", "cad");
    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["CA$15"]);
  });

  it("keeps the direct-listed control available while Save card is checked", () => {
    const { getByLabelText } = renderCheckout(directListedState({ willSaveCard: true }), directListedCart);

    expect(getByLabelText("Currency")).toBeTruthy();
  });

  it("renders canonical totals when USD is selected without losing the listed option", () => {
    const { getAllByLabelText, getByLabelText } = renderCheckout(
      directListedState({ buyerCurrency: "usd" }),
      directListedCart,
    );
    const picker = getByLabelText("Currency");

    expect(picker).toHaveProperty("value", "usd");
    expect(Array.from(picker.querySelectorAll("option"), (option) => option.value)).toEqual(["usd", "cad"]);
    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$10"]);
  });

  it("keeps explicit USD selected after a tip makes the listed currency unavailable", () => {
    const { getAllByLabelText, getByLabelText } = renderCheckout(
      directListedState({
        buyerCurrency: "usd",
        products: [stateProduct({ price: 1_000, hasTippingEnabled: true })],
        tip: { type: "fixed", amount: 350, presentmentAmount: 437, presentmentCurrency: "cad" },
      }),
      {
        ...directListedCart,
        items: [
          cartItem({
            product: cartProduct({ currency_code: "cad", exchange_rate: 1.5, has_tipping_enabled: true }),
            price: 1_500,
          }),
        ],
      },
    );
    const picker = getByLabelText("Currency");

    expect(picker).toHaveProperty("value", "usd");
    expect(Array.from(picker.querySelectorAll<HTMLOptionElement>("option"), (option) => option.value)).toEqual([
      "usd",
      "cad",
    ]);
    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$10"]);
    expect(getByLabelText("Tip").getAttribute("value")).toBe("3.50");
  });

  it("keeps the listed total while a switch to the saved card is being re-quoted", () => {
    // The held quote was minted for a new card, which charges the listed currency. Reading the
    // display off the surface being switched TO flips the same held amounts to USD for the length
    // of the round trip, so the total changes twice under the buyer. Paying stays blocked on the
    // live `surcharges`, which is pending here.
    const { getAllByLabelText } = renderCheckout(
      directListedState({
        buyerCurrency: "cad",
        usingSavedCard: true,
        surcharges: { type: "pending" },
        buyerCurrencyRemint: {
          surcharges: directListedSurcharges,
          previousCurrency: "cad",
          surfaceSwitch: true,
          previousUsingSavedCard: false,
        },
      }),
      directListedCart,
    );

    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["CA$15"]);
  });

  it("does not expose quote-backed currencies after a tip moves the cart to canonical USD", () => {
    const { getAllByLabelText, queryByLabelText } = renderCheckout(
      directListedState({
        products: [stateProduct({ price: 1_000, hasTippingEnabled: true })],
        tip: { type: "percentage", percentage: 10 },
      }),
      {
        ...directListedCart,
        items: [
          cartItem({
            product: cartProduct({ currency_code: "cad", exchange_rate: 1.5, has_tipping_enabled: true }),
            price: 1_500,
          }),
        ],
      },
    );

    expect(queryByLabelText("Currency")).toBeNull();
    expect(getAllByLabelText("Price").map((node) => node.textContent)).toEqual(["US$10"]);
  });
});

describe("Checkout currency picker", () => {
  const quotedSurcharges: SurchargesResponse = {
    vat_id_valid: false,
    has_vat_id_input: false,
    shipping_rate_cents: 0,
    tax_cents: 0,
    tax_included_cents: 0,
    subtotal: 1_000,
    detected_buyer_currency: "cad",
    available_buyer_currencies: [
      { code: "usd", label: "$ (US Dollars)" },
      { code: "cad", label: "CA$ (Canadian Dollars)" },
    ],
    buyer_currency_quote: {
      token: "quote-token",
      currency: "cad",
      canonical_total_cents: 1_000,
      presentment_total_cents: 1_250,
      charge_presentment_total_cents: 1_250,
      rate: 1.25,
      subunit_to_unit: 100,
      expires_at: "2999-01-01T00:00:00Z",
      line_allocations: [
        {
          permalink: "prod",
          price_cents: 1_250,
          tip_cents: 0,
          tax_cents: 0,
          shipping_cents: 0,
          total_cents: 1_250,
        },
      ],
    },
  };
  const cart: CartState = { items: [cartItem()], discountCodes: [] };

  it("shows the picker on a card checkout that can settle more than one currency", () => {
    const { getByLabelText } = renderCheckout(
      buildState({ surcharges: { type: "loaded", result: quotedSurcharges } }),
      cart,
    );
    expect(getByLabelText("Currency")).toBeTruthy();
  });

  it("renders the picker directly below the Total row", () => {
    const { getByLabelText, getByText } = renderCheckout(
      buildState({ surcharges: { type: "loaded", result: quotedSurcharges } }),
      cart,
    );
    const picker = getByLabelText("Currency");
    const total = getByText("Total");
    expect(total.compareDocumentPosition(picker) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("hides the picker and keeps USD totals when Apple Pay is selected", () => {
    const { queryByLabelText, getAllByText } = renderCheckout(
      buildState({
        paymentElementType: "apple_pay",
        surcharges: { type: "loaded", result: quotedSurcharges },
      }),
      cart,
    );
    expect(queryByLabelText("Currency")).toBeNull();
    expect(getAllByText("US$10").length).toBeGreaterThan(0);
  });

  it("hides the picker when PayPal is selected", () => {
    const { queryByLabelText } = renderCheckout(
      buildState({
        paymentMethod: "paypal",
        surcharges: { type: "loaded", result: quotedSurcharges },
      }),
      cart,
    );
    expect(queryByLabelText("Currency")).toBeNull();
  });

  it("hides the picker when a new card will be saved", () => {
    const { queryByLabelText } = renderCheckout(
      buildState({
        willSaveCard: true,
        surcharges: { type: "loaded", result: quotedSurcharges },
      }),
      cart,
    );

    expect(queryByLabelText("Currency")).toBeNull();
  });

  it("keeps the picker and the summary in place while the chosen currency is re-quoted", () => {
    const { getByLabelText, getByText } = renderCheckout(
      buildState({
        buyerCurrency: "usd",
        surcharges: { type: "pending" },
        buyerCurrencyRemint: { surcharges: quotedSurcharges, previousCurrency: "cad" },
      }),
      cart,
    );

    expect(getByLabelText("Currency")).toBeTruthy();
    expect(getByText("Total")).toBeTruthy();
    expect(getByText("Subtotal")).toBeTruthy();
    expect(getByText("Updating total…")).toBeTruthy();
  });

  it("leaves the focused select in the document across the re-quote", () => {
    const loaded = buildState({ surcharges: { type: "loaded", result: quotedSurcharges } });
    const { getByLabelText, rerender } = renderCheckout(loaded, cart);
    const select = getByLabelText("Currency");
    select.focus();

    rerender(
      <StateContext.Provider
        value={[
          buildState({
            buyerCurrency: "usd",
            surcharges: { type: "pending" },
            buyerCurrencyRemint: { surcharges: quotedSurcharges, previousCurrency: "cad" },
          }),
          vi.fn(),
        ]}
      >
        <Checkout discoverUrl="#" cart={cart} updateCart={vi.fn()} />
      </StateContext.Provider>,
    );

    expect(getByLabelText("Currency")).toBe(select);
    expect(document.activeElement).toBe(select);
  });

  it("keeps a custom buyer-currency tip as typed while the quote remints around canonical rounding", () => {
    const state = buildState({
      products: [stateProduct({ hasTippingEnabled: true })],
      tip: { type: "fixed", amount: 350, presentmentAmount: 437, presentmentCurrency: "cad" },
      surcharges: {
        type: "loaded",
        result: {
          ...quotedSurcharges,
          subtotal: 1_350,
          buyer_currency_quote: quotedSurcharges.buyer_currency_quote
            ? {
                ...quotedSurcharges.buyer_currency_quote,
                canonical_total_cents: 1_350,
                presentment_total_cents: 1_688,
                charge_presentment_total_cents: 1_688,
                line_allocations: [
                  {
                    permalink: "prod",
                    price_cents: 1_250,
                    tip_cents: 438,
                    tax_cents: 0,
                    shipping_cents: 0,
                    total_cents: 1_688,
                  },
                ],
              }
            : null,
        },
      },
    });
    const { getByLabelText } = renderCheckout(state, {
      items: [cartItem({ product: cartProduct({ has_tipping_enabled: true }) })],
      discountCodes: [],
    });

    expect(getByLabelText("Tip").getAttribute("value")).toBe("4.37");
  });

  it("names the currency the server refused instead of switching the total quietly", () => {
    const { getByText } = renderCheckout(
      buildState({
        buyerCurrency: "cad",
        unavailableBuyerCurrency: "gbp",
        surcharges: { type: "loaded", result: quotedSurcharges },
      }),
      cart,
    );

    expect(getByText(/We can't charge this cart in £ \(British Pounds\)/u)).toBeTruthy();
  });

  it("still names the refused currency when only one currency is left to offer", () => {
    // Refusing a currency usually withdraws it from the menu, which can leave a single option and
    // unmount the picker — exactly when the buyer needs to be told why their choice did not take.
    const usdOnly: SurchargesResponse = {
      ...quotedSurcharges,
      detected_buyer_currency: "usd",
      available_buyer_currencies: [{ code: "usd", label: "$ (US Dollars)" }],
      buyer_currency_quote: null,
    };
    const { getByText, queryByLabelText } = renderCheckout(
      buildState({
        buyerCurrency: null,
        unavailableBuyerCurrency: "gbp",
        surcharges: { type: "loaded", result: usdOnly },
      }),
      cart,
    );

    expect(queryByLabelText("Currency")).toBeNull();
    expect(getByText(/We can't charge this cart in £ \(British Pounds\)/u)).toBeTruthy();
  });

  it("stops saying the total is updating once the re-quote has failed", () => {
    const { queryByText, getByText } = renderCheckout(
      buildState({
        buyerCurrency: "usd",
        surcharges: { type: "error" },
        buyerCurrencyRemint: { surcharges: quotedSurcharges, previousCurrency: "cad" },
      }),
      cart,
    );

    expect(queryByText("Updating total…")).toBeNull();
    expect(getByText("Total")).toBeTruthy();
  });

  it("replaces an unavailable saved currency with the resolved picker value", () => {
    const dispatch = vi.fn();
    const { getByLabelText } = renderCheckout(
      buildState({
        buyerCurrency: "gbp",
        surcharges: { type: "loaded", result: quotedSurcharges },
      }),
      cart,
      dispatch,
    );

    expect(getByLabelText("Currency")).toBeTruthy();
    expect(dispatch).toHaveBeenCalledWith({ type: "set-value", buyerCurrency: "cad" });
  });
});
