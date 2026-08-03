// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import type { Discount } from "$app/parsers/checkout";

import { formatDiscountAmount } from "$app/components/Product";
import { buyerLocalPriceCentsForSelection } from "$app/components/Product/ConfigurationSelector";

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

describe("buyerLocalPriceCentsForSelection", () => {
  it("omits the one-unit fallback when a cart discount applies to multiple units", () => {
    const discount: Discount = {
      type: "fixed",
      cents: 100,
      once_per_cart: true,
      ...conditions,
    };

    expect(buyerLocalPriceCentsForSelection(900, discount, 2)).toBeNull();
    expect(buyerLocalPriceCentsForSelection(900, discount, 1)).toBe(900);
  });
});
