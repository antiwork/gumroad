// @vitest-environment happy-dom
import * as React from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { describe, expect, it, vi } from "vitest";

import type { CartPurchaseResult } from "$app/data/purchase";

import {
  buildBuyerCurrencyQuoteRecoveryDeps,
  recoverFromInvalidBuyerCurrencyQuote,
  refreshedRatesFromLineItems,
  useLatestCartGetter,
  withRefreshedOfferCodes,
} from "$app/components/Checkout/buyerCurrencyQuoteRecovery";
import type { CartItem, CartState, Product as CartProduct } from "$app/components/Checkout/cartState";

const cartProduct = (overrides: Partial<CartProduct> = {}): CartProduct => ({
  id: "product-id",
  permalink: "eur",
  name: "Product",
  creator: { id: "seller-a", name: "Seller A", profile_url: "#", avatar_url: "" },
  url: "#",
  thumbnail_url: null,
  currency_code: "eur",
  price_cents: 2_000,
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
  exchange_rate: 0.879624,
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
  price: 2_000,
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

const cartWith = (items: CartItem[]): CartState => ({ items, discountCodes: [] });
// A refused line item as the server actually sends it: `Order::ResponseHelpers#error_response`
// attaches a freshly built `updated_product` whose `exchange_rate` is today's stored rate.
// Pass `null` for the product to model the shape the server sends when it has no purchase to
// build one from, which is a refusal the recovery has to survive without a rate to read.
const refusedLine = (product: CartProduct | null): CartPurchaseResult["lineItems"][string] => ({
  success: false,
  error_message: "The local-currency price changed or expired.",
  name: product?.name ?? null,
  formatted_price: "$20",
  error_code: "buyer_currency_quote_invalid",
  is_tax_mismatch: false,
  card_country: null,
  ip_country: null,
  updated_product: product
    ? {
        product,
        recurrence: null,
        price: 2_000,
        option_id: null,
        rent: false,
        quantity: 1,
        affiliate_id: null,
        recommended_by: null,
        call_start_time: null,
        accepted_offer: null,
        pay_in_installments: false,
        force_new_subscription: false,
      }
    : null,
});

const linesFor = (products: CartProduct[]): CartPurchaseResult["lineItems"] =>
  Object.fromEntries(products.map((product) => [`${product.permalink} `, refusedLine(product)]));

const run = (cart: CartState, lineItems: CartPurchaseResult["lineItems"]) => {
  const setCart = vi.fn<(cart: CartState) => void>();
  const requote = vi.fn<(cart: CartState) => void>();
  recoverFromInvalidBuyerCurrencyQuote({ lineItems, getCart: () => cart, setCart, requote });
  return { setCart, requote };
};

// This is the whole point of the recovery: the buyer's cart carries the exchange rate that was
// current when the page rendered, and the charge was refused because the server's rate has since
// moved. Re-quoting on the stale rate would mint the same rejected total again, so the rate has to
// be refreshed before the retry — and it is read out of the refusal response, because creating the
// order soft-deletes the buyer's cart, so there is no cart left on the server to re-read it from.
describe("recoverFromInvalidBuyerCurrencyQuote", () => {
  it("re-quotes with the server's current offer while preserving URL attribution", () => {
    const oldDiscount = {
      type: "fixed" as const,
      cents: 500,
      product_ids: null,
      expires_at: null,
      minimum_quantity: null,
      duration_in_billing_cycles: null,
      minimum_amount_cents: null,
    };
    const currentDiscount = { ...oldDiscount, cents: 300 };
    const cart = {
      ...cartWith([cartItem()]),
      discountCodes: [{ code: "SAVE", products: { eur: oldDiscount }, fromUrl: true }],
    };

    expect(withRefreshedOfferCodes(cart, [{ code: "SAVE", products: { eur: currentDiscount } }]).discountCodes).toEqual(
      [{ code: "SAVE", products: { eur: currentDiscount }, fromUrl: true }],
    );
  });

  it("keeps the cart's discounts when the refusal carries no replacement offers", () => {
    // An expired amount token refuses with an empty offer list. Adopting it as the new discount
    // list would retry the charge at full price.
    const discountCodes = [
      {
        code: "SAVE",
        products: {
          eur: {
            type: "fixed" as const,
            cents: 500,
            product_ids: null,
            expires_at: null,
            minimum_quantity: null,
            duration_in_billing_cycles: null,
            minimum_amount_cents: null,
          },
        },
        fromUrl: true,
      },
    ];
    const cart = { ...cartWith([cartItem()]), discountCodes };

    expect(withRefreshedOfferCodes(cart, []).discountCodes).toEqual(discountCodes);
  });

  it("re-quotes on the server's current rate, not the one the page rendered with", () => {
    const cart = cartWith([cartItem()]);

    const { setCart, requote } = run(cart, linesFor([cartProduct({ exchange_rate: 0.881_5 })]));

    expect(setCart).toHaveBeenCalledTimes(1);
    expect(setCart.mock.calls[0]?.[0].items[0]?.product.exchange_rate).toBe(0.881_5);
    expect(requote).toHaveBeenCalledTimes(1);
    expect(requote.mock.calls[0]?.[0].items[0]?.product.exchange_rate).toBe(0.881_5);
    // The refreshed cart is a new object, so the retry cannot be quoting the stale one.
    expect(requote.mock.calls[0]?.[0]).not.toBe(cart);
  });

  it("leaves the buyer's own choices alone while swapping the rate", () => {
    const cart = cartWith([
      cartItem({ quantity: 3, price: 2_500, option_id: "variant-1", accepted_offer: { id: "offer-1" } }),
    ]);

    const { requote } = run(cart, linesFor([cartProduct({ exchange_rate: 0.9 })]));

    const item = requote.mock.calls[0]?.[0].items[0];
    expect(item?.quantity).toBe(3);
    expect(item?.price).toBe(2_500);
    expect(item?.option_id).toBe("variant-1");
    expect(item?.accepted_offer).toEqual({ id: "offer-1" });
  });

  // Saving the cart back to the server on every rejected quote would be a pointless write, and
  // the checkout's cart-save effect fires on any new object identity.
  it("does not re-save the cart when the rate has not moved", () => {
    const cart = cartWith([cartItem()]);

    const { setCart, requote } = run(cart, linesFor([cartProduct()]));

    expect(setCart).not.toHaveBeenCalled();
    expect(requote).toHaveBeenCalledWith(cart);
  });

  // The buyer must never be left on a disabled Pay button. A refusal that carries no usable
  // product still gets a re-quote: it can fail the same way, but visibly, with the alert shown.
  it("still re-quotes when the response carries no product to read a rate from", () => {
    const cart = cartWith([cartItem()]);

    // A refusal with no line items at all, one shaped like the server's short error form
    // (`error_message` and `updated_product` are both optional on it), and one that carries the
    // full error shape but an explicitly null product.
    const cases: CartPurchaseResult["lineItems"][] = [
      {},
      { "eur ": { success: false } },
      { "eur ": refusedLine(null) },
    ];

    for (const lineItems of cases) {
      const { setCart, requote } = run(cart, lineItems);
      expect(setCart).not.toHaveBeenCalled();
      expect(requote).toHaveBeenCalledWith(cart);
    }
  });

  // An unusable rate (zero, negative, non-finite, or absent because the product is not in the
  // response) would make the browser's price conversion produce Infinity or NaN and render a
  // garbage total.
  it("keeps the existing rate rather than adopting an unusable one", () => {
    const cart = cartWith([cartItem()]);

    for (const exchange_rate of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      const { setCart, requote } = run(cart, linesFor([cartProduct({ exchange_rate })]));
      expect(setCart).not.toHaveBeenCalled();
      expect(requote.mock.calls[0]?.[0].items[0]?.product.exchange_rate).toBe(0.879624);
    }

    const { requote } = run(cart, linesFor([cartProduct({ permalink: "other", exchange_rate: 0.5 })]));
    expect(requote.mock.calls[0]?.[0].items[0]?.product.exchange_rate).toBe(0.879624);
  });

  // Rates are per listed currency, so a mixed cart must pick up each product's own rate and only
  // the ones that actually moved.
  it("refreshes each product's own rate in a multi-item cart", () => {
    const usd = cartItem({ product: cartProduct({ permalink: "usd", currency_code: "usd", exchange_rate: 1 }) });
    const eur = cartItem();
    const cart = cartWith([usd, eur]);

    const { requote } = run(
      cart,
      linesFor([
        cartProduct({ permalink: "usd", currency_code: "usd", exchange_rate: 1 }),
        cartProduct({ exchange_rate: 0.95 }),
      ]),
    );

    const items = requote.mock.calls[0]?.[0].items;
    expect(items?.[0]?.product.exchange_rate).toBe(1);
    expect(items?.[1]?.product.exchange_rate).toBe(0.95);
    // The untouched item keeps its identity, so nothing downstream re-renders it needlessly.
    expect(items?.[0]).toBe(usd);
  });

  // Only refused lines carry an `updated_product`, so a rate must never be collected from a line
  // that is missing one. This covers the refused-but-productless case; a line that already
  // succeeded is excluded by the `result.success` check, which TypeScript enforces — the success
  // shape has no `updated_product` field to read at all, so that branch cannot regress silently.
  it("collects a rate only from lines that carry a product", () => {
    const rates = refreshedRatesFromLineItems({
      "eur ": refusedLine(cartProduct({ exchange_rate: 0.9 })),
      "usd ": { success: false, error_message: "no product on this line" },
    });

    expect([...rates.entries()]).toEqual([["eur", 0.9]]);
  });

  // Charging is a network round trip, and the checkout is editable while it is in flight: the
  // buyer can bump a quantity or change an option between clicking Pay and the refusal arriving.
  // The recovery has to merge into whatever they are holding when it runs, not into the cart from
  // the render that kicked off the charge — otherwise it saves the older selections back and
  // quotes them, quietly undoing the edit. useLatestCartGetter is what supplies that, and the
  // window it closes is React's effect flush, so answering from inside a re-render reproduces it.
  it("reads the edited cart even when the refusal lands before React flushes effects", () => {
    const setCart = vi.fn<(cart: CartState) => void>();
    const requote = vi.fn<(cart: CartState) => void>();

    let recover: () => void = () => {};
    const Checkout = ({ cart, onRender }: { cart: CartState; onRender?: () => void }) => {
      const getCart = useLatestCartGetter(cart);
      recover = () =>
        recoverFromInvalidBuyerCurrencyQuote({
          lineItems: linesFor([cartProduct({ exchange_rate: 0.9 })]),
          getCart,
          setCart,
          requote,
        });
      onRender?.();
      return null;
    };

    const root = createRoot(document.createElement("div"));
    flushSync(() => root.render(React.createElement(Checkout, { cart: cartWith([cartItem({ quantity: 1 })]) })));

    // The buyer bumps the quantity while the charge is in flight, and the refusal is handled while
    // that render is still in progress — before any effect it queued has run.
    flushSync(() =>
      root.render(
        React.createElement(Checkout, {
          cart: cartWith([cartItem({ quantity: 3 })]),
          onRender: () => recover(),
        }),
      ),
    );

    expect(setCart.mock.calls[0]?.[0].items[0]?.quantity).toBe(3);
    expect(requote.mock.calls[0]?.[0].items[0]?.quantity).toBe(3);
    expect(requote.mock.calls[0]?.[0].items[0]?.product.exchange_rate).toBe(0.9);
  });
});

describe("buildBuyerCurrencyQuoteRecoveryDeps", () => {
  // The bug being fixed was one line in the checkout's refusal branch that re-quoted straight
  // from the cart already in memory. Every test above exercises the helpers, so restoring that
  // line would leave them all green while restoring the loop. These two cover the wiring itself.
  it("converts the merged cart it is handed, not the cart still on the page", () => {
    const staleCart = cartWith([cartItem()]);
    const mergedCart = cartWith([cartItem({ product: cartProduct({ exchange_rate: 0.78 }) })]);
    const getProducts = vi.fn((cart: CartState) => cart.items.map((item) => item.product.exchange_rate));
    const dispatchUpdateProducts = vi.fn();

    const deps = buildBuyerCurrencyQuoteRecoveryDeps({
      // Deliberately the pre-merge cart: re-reading the page's cart instead of using the argument
      // is exactly the regression, so this getter must not be what requote converts.
      getLatestCart: () => staleCart,
      setCart: vi.fn(),
      getProducts,
      dispatchUpdateProducts,
    });
    deps.requote(mergedCart);

    expect(getProducts).toHaveBeenCalledWith(mergedCart);
    expect(dispatchUpdateProducts).toHaveBeenCalledWith([0.78]);
  });

  it("persists through the caller's setter and reads the latest cart", () => {
    const latest = cartWith([cartItem({ quantity: 5 })]);
    const setCart = vi.fn();

    const deps = buildBuyerCurrencyQuoteRecoveryDeps({
      getLatestCart: () => latest,
      setCart,
      getProducts: (cart: CartState) => cart.items,
      dispatchUpdateProducts: vi.fn(),
    });

    expect(deps.getCart()).toBe(latest);
    deps.setCart(latest);
    expect(setCart).toHaveBeenCalledWith(latest);
  });
});
