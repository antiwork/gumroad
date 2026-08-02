// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import type { Discount } from "$app/parsers/checkout";

import { formatDiscountAmount } from "$app/components/Product";

const conditions = {
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

describe("formatDiscountAmount", () => {
  it("shows the configured cart discount rather than its current allocation", () => {
    const discount: Discount = {
      type: "fixed",
      cents: 0,
      once_per_cart: true,
      once_per_cart_amount_cents: 1_500,
      ...conditions,
    };

    expect(formatDiscountAmount(discount, { currencyCode: "usd" })).toBe("$15");
  });
});
