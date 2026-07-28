import { describe, expect, it, vi } from "vitest";

import { recoverFromInvalidBuyerCurrencyQuote } from "$app/components/Checkout/buyerCurrencyQuoteRecovery";
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

// A reload that answers with the given props, or fails when `props` is the string "error".
const reloaderReturning =
  (props: unknown | "error") => (callbacks: { onSuccess: (props: unknown) => void; onError: () => void }) =>
    props === "error" ? callbacks.onError() : callbacks.onSuccess(props);

const run = (cart: CartState, reload: ReturnType<typeof reloaderReturning>) => {
  const setCart = vi.fn();
  const requote = vi.fn();
  recoverFromInvalidBuyerCurrencyQuote({ reloadCartProps: reload, cart, setCart, requote });
  return { setCart, requote };
};

// This is the whole point of the recovery: the buyer's cart carries the exchange rate that was
// current when the page rendered, and the charge was refused because the server's rate has since
// moved. Re-quoting on the stale rate would mint the same rejected total again, so the rate has to
// be refreshed from the server before the retry.
describe("recoverFromInvalidBuyerCurrencyQuote", () => {
  it("re-quotes on the server's current rate, not the one the page rendered with", () => {
    const cart = cartWith([cartItem()]);
    const refreshed = cartWith([cartItem({ product: cartProduct({ exchange_rate: 0.881_5 }) })]);

    const { setCart, requote } = run(cart, reloaderReturning({ cart: refreshed }));

    expect(setCart).toHaveBeenCalledTimes(1);
    expect(setCart.mock.calls[0]?.[0].items[0].product.exchange_rate).toBe(0.881_5);
    expect(requote).toHaveBeenCalledTimes(1);
    expect(requote.mock.calls[0]?.[0].items[0].product.exchange_rate).toBe(0.881_5);
    // The refreshed cart is a new object, so the retry cannot be quoting the stale one.
    expect(requote.mock.calls[0]?.[0]).not.toBe(cart);
  });

  it("leaves the buyer's own choices alone while swapping the rate", () => {
    const cart = cartWith([
      cartItem({ quantity: 3, price: 2_500, option_id: "variant-1", accepted_offer: { id: "offer-1" } }),
    ]);
    const refreshed = cartWith([cartItem({ product: cartProduct({ exchange_rate: 0.9 }) })]);

    const { requote } = run(cart, reloaderReturning({ cart: refreshed }));

    const item = requote.mock.calls[0]?.[0].items[0];
    expect(item.quantity).toBe(3);
    expect(item.price).toBe(2_500);
    expect(item.option_id).toBe("variant-1");
    expect(item.accepted_offer).toEqual({ id: "offer-1" });
  });

  // Saving the cart back to the server on every rejected quote would be a pointless write, and
  // the checkout's cart-save effect fires on any new object identity.
  it("does not re-save the cart when the rate has not moved", () => {
    const cart = cartWith([cartItem()]);

    const { setCart, requote } = run(cart, reloaderReturning({ cart: cartWith([cartItem()]) }));

    expect(setCart).not.toHaveBeenCalled();
    expect(requote).toHaveBeenCalledWith(cart);
  });

  // The buyer must never be left on a disabled Pay button. A failed reload still gets a re-quote:
  // it can fail the same way, but visibly, with the alert already shown.
  it("still re-quotes when the reload itself fails", () => {
    const cart = cartWith([cartItem()]);

    const { setCart, requote } = run(cart, reloaderReturning("error"));

    expect(setCart).not.toHaveBeenCalled();
    expect(requote).toHaveBeenCalledWith(cart);
  });

  // A partial reload merges into the page's existing props. If an unrelated prop ever changes
  // shape, the recovery must degrade to a plain re-quote rather than throwing and stranding the
  // buyer mid-checkout.
  it("degrades to a plain re-quote when the reloaded props are not the shape it expects", () => {
    const cart = cartWith([cartItem()]);

    for (const props of [{}, { cart: null }, { cart: "not a cart" }, undefined]) {
      const { setCart, requote } = run(cart, reloaderReturning(props));
      expect(setCart).not.toHaveBeenCalled();
      expect(requote).toHaveBeenCalledWith(cart);
    }
  });

  // An unusable rate (zero, negative, or absent because the item is gone from the server's cart)
  // would make the browser's price conversion produce Infinity or NaN and render a garbage total.
  it("keeps the existing rate rather than adopting an unusable one", () => {
    const cart = cartWith([cartItem()]);

    for (const exchange_rate of [0, -1]) {
      const { requote } = run(
        cart,
        reloaderReturning({ cart: cartWith([cartItem({ product: cartProduct({ exchange_rate }) })]) }),
      );
      expect(requote.mock.calls[0]?.[0].items[0].product.exchange_rate).toBe(0.879624);
    }

    const { requote } = run(
      cart,
      reloaderReturning({ cart: cartWith([cartItem({ product: cartProduct({ permalink: "other" }) })]) }),
    );
    expect(requote.mock.calls[0]?.[0].items[0].product.exchange_rate).toBe(0.879624);
  });

  // Rates are per listed currency, so a mixed cart must pick up each product's own rate and only
  // the ones that actually moved.
  it("refreshes each product's own rate in a multi-item cart", () => {
    const usd = cartItem({ product: cartProduct({ permalink: "usd", currency_code: "usd", exchange_rate: 1 }) });
    const eur = cartItem();
    const cart = cartWith([usd, eur]);
    const refreshed = cartWith([
      cartItem({ product: cartProduct({ permalink: "usd", currency_code: "usd", exchange_rate: 1 }) }),
      cartItem({ product: cartProduct({ exchange_rate: 0.95 }) }),
    ]);

    const { requote } = run(cart, reloaderReturning({ cart: refreshed }));

    const items = requote.mock.calls[0]?.[0].items;
    expect(items[0].product.exchange_rate).toBe(1);
    expect(items[1].product.exchange_rate).toBe(0.95);
    // The untouched item keeps its identity, so nothing downstream re-renders it needlessly.
    expect(items[0]).toBe(usd);
  });
});
