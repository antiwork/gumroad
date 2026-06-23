import { describe, expect, it } from "vitest";

import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";

import { type ProductToAdd } from "$app/components/Checkout/cartState";

import { computeInitialCheckout } from "./initialCheckout";

const baseProduct = PLACEHOLDER_CART_ITEM.product;

const makeProductToAdd = (overrides: {
  permalink: string;
  creatorId: string;
  price?: number;
  optionId?: string | null;
  withAnalytics?: boolean;
}): ProductToAdd => ({
  product: {
    ...baseProduct,
    permalink: overrides.permalink,
    creator: { ...baseProduct.creator, id: overrides.creatorId },
    analytics: overrides.withAnalytics
      ? { google_analytics_id: "GA-1", facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: false }
      : baseProduct.analytics,
  },
  recurrence: null,
  price: overrides.price ?? 100,
  option_id: overrides.optionId ?? null,
  rent: false,
  quantity: 1,
  affiliate_id: null,
  recommended_by: null,
  call_start_time: null,
  accepted_offer: null,
  pay_in_installments: false,
  force_new_subscription: false,
});

const makeArgs = (
  addProducts: ProductToAdd[],
  overrides: Partial<Parameters<typeof computeInitialCheckout>[0]> = {},
) => ({
  cart: null,
  clearCart: false,
  addProducts,
  maxAllowedCartProducts: 50,
  url: new URL("https://gumroad.com/checkout"),
  documentReferrer: "",
  ...overrides,
});

describe("computeInitialCheckout", () => {
  it("emits exactly one begin_checkout event per seller (no per-render duplication) — gumroad-private#658", () => {
    const products = [
      makeProductToAdd({ permalink: "a", creatorId: "seller-1" }),
      makeProductToAdd({ permalink: "b", creatorId: "seller-1" }),
      makeProductToAdd({ permalink: "c", creatorId: "seller-2" }),
    ];

    const result = computeInitialCheckout(makeArgs(products));

    expect(result.beginCheckoutEvents).toHaveLength(2);
    const sellerIds = result.beginCheckoutEvents.map((e) => e.seller_id).sort();
    expect(sellerIds).toEqual(["seller-1", "seller-2"]);
    expect(result.beginCheckoutEvents.map((e) => e.action)).toEqual(["begin_checkout", "begin_checkout"]);
  });

  it("is pure: repeated invocations on a shared multi-product array produce identical results (the render-loop regression + no input mutation)", () => {
    // Multi-element + a stable reference: if the function mutated the caller's
    // array (e.g. an in-place reverse), successive calls would diverge. A
    // single-element array would hide that, since reversing one item is a no-op.
    const products = [
      makeProductToAdd({ permalink: "a", creatorId: "seller-1" }),
      makeProductToAdd({ permalink: "b", creatorId: "seller-2" }),
    ];
    const orderBefore = products.map((p) => p.product.permalink);

    // Simulate the multiple renders that the old function-initializer triggered.
    const cartOrders = Array.from({ length: 10 }, () =>
      computeInitialCheckout(makeArgs(products)).cart.items.map((i) => i.product.permalink),
    );

    // Every render must yield the same cart order...
    for (const order of cartOrders) expect(order).toEqual(cartOrders[0]);
    // ...and the caller's input array must never be mutated.
    expect(products.map((p) => p.product.permalink)).toEqual(orderBefore);
  });

  it("collects sellers to track, deduped per begin_checkout but one tracking entry per cart item", () => {
    const products = [
      makeProductToAdd({ permalink: "a", creatorId: "seller-1", withAnalytics: true }),
      makeProductToAdd({ permalink: "b", creatorId: "seller-2", withAnalytics: true }),
    ];

    const result = computeInitialCheckout(makeArgs(products));

    expect(result.sellersToTrack.map((s) => s.id).sort()).toEqual(["seller-1", "seller-2"]);
    expect(result.overLimit).toBe(false);
  });

  it("flags overLimit and does not emit tracking when the cart exceeds the max", () => {
    const products = [
      makeProductToAdd({ permalink: "a", creatorId: "seller-1" }),
      makeProductToAdd({ permalink: "b", creatorId: "seller-1" }),
      makeProductToAdd({ permalink: "c", creatorId: "seller-1" }),
    ];

    const result = computeInitialCheckout(makeArgs(products, { maxAllowedCartProducts: 2 }));

    expect(result.overLimit).toBe(true);
    expect(result.beginCheckoutEvents).toHaveLength(0);
    expect(result.sellersToTrack).toHaveLength(0);
  });

  it("emits no events when there are no add_products (direct cart visit)", () => {
    const result = computeInitialCheckout(makeArgs([]));

    expect(result.beginCheckoutEvents).toHaveLength(0);
    expect(result.sellersToTrack).toHaveLength(0);
    expect(result.overLimit).toBe(false);
    expect(result.cart.items).toHaveLength(0);
  });

  it("adds the products to the returned cart", () => {
    const products = [
      makeProductToAdd({ permalink: "a", creatorId: "seller-1" }),
      makeProductToAdd({ permalink: "b", creatorId: "seller-2" }),
    ];

    const result = computeInitialCheckout(makeArgs(products));

    expect(result.cart.items.map((i) => i.product.permalink).sort()).toEqual(["a", "b"]);
    expect(result.cart.rejectPppDiscount).toBe(false);
  });
});
