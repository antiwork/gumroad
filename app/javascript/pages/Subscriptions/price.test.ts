import { describe, expect, it } from "vitest";

import { initialSubscriptionUnitPrice, selectedSubscriptionTotal } from "$app/pages/Subscriptions/price";
import type { Discount } from "$app/parsers/checkout";

const oncePerCartDiscount: Discount = {
  type: "fixed",
  cents: 100,
  once_per_cart: true,
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

describe("subscription pricing", () => {
  it("does not scale a cart-level discount when quantity changes", () => {
    const unitPrice = initialSubscriptionUnitPrice({
      price: 1_900,
      pre_discount_price: 2_000,
      quantity: 2,
      discount: oncePerCartDiscount,
    });

    expect(unitPrice).toBe(1_000);
    expect(selectedSubscriptionTotal({ unitPrice, quantity: 3, discount: oncePerCartDiscount })).toBe(2_900);
  });

  it("keeps legacy per-item pricing unchanged", () => {
    const discount = { ...oncePerCartDiscount, once_per_cart: false };
    const unitPrice = initialSubscriptionUnitPrice({
      price: 1_800,
      pre_discount_price: 2_000,
      quantity: 2,
      discount,
    });

    expect(unitPrice).toBe(900);
    expect(selectedSubscriptionTotal({ unitPrice, quantity: 3, discount })).toBe(2_700);
  });
});
