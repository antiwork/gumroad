// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import type { Discount } from "$app/parsers/checkout";

import { getUndiscountedPWYWPrice } from "$app/components/Product/CtaButton";

const conditions = {
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

describe("getUndiscountedPWYWPrice", () => {
  it("restores the configured cart discount rather than its initial allocation", () => {
    const discount: Discount = {
      type: "fixed",
      cents: 1_000,
      once_per_cart: true,
      once_per_cart_amount_cents: 1_500,
      ...conditions,
    };

    expect(getUndiscountedPWYWPrice(500, discount, 1)).toBe(2_000);
  });

  it("restores the product minimum when the cart discount is clamped to the currency minimum", () => {
    const discount: Discount = {
      type: "fixed",
      cents: 975,
      once_per_cart: true,
      once_per_cart_amount_cents: 975,
      ...conditions,
    };

    expect(getUndiscountedPWYWPrice(99, discount, 1, { discounted: 99, undiscounted: 1_000 })).toBe(1_000);
  });
});
