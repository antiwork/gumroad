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
});
