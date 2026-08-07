// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import {
  computeDiscountedPriceCents,
  computeStandalonePrice,
  computeStandaloneTotalCents,
  transitionCustomizablePrice,
} from "$app/components/BundleEdit/utils";

const product = (priceCents: number, quantity = 1, priceDifference: number | null = null) => ({
  price_cents: priceCents,
  quantity,
  variants:
    priceDifference === null
      ? null
      : {
          selected_id: "v1",
          list: [
            { id: "v1", price_difference: priceDifference },
            { id: "v2", price_difference: 99_999 },
          ],
        },
});

describe("computeStandalonePrice", () => {
  it("multiplies the base price by quantity", () => {
    expect(computeStandalonePrice(product(500, 3))).toBe(1500);
  });

  it("adds only the selected variant's price difference", () => {
    expect(computeStandalonePrice(product(500, 2, 250))).toBe(1500);
  });
});

describe("computeStandaloneTotalCents", () => {
  it("sums the standalone prices of all products", () => {
    expect(computeStandaloneTotalCents([product(500), product(1000, 2), product(200, 1, 100)])).toBe(2800);
  });

  it("is 0 for an empty bundle", () => {
    expect(computeStandaloneTotalCents([])).toBe(0);
  });
});

describe("computeDiscountedPriceCents", () => {
  it("rounds to the nearest cent", () => {
    // 999 * 0.8 = 799.2 → 799
    expect(computeDiscountedPriceCents(999, 20)).toBe(799);
  });

  it("returns the full total at 0% and zero at 100%", () => {
    expect(computeDiscountedPriceCents(2800, 0)).toBe(2800);
    expect(computeDiscountedPriceCents(2800, 100)).toBe(0);
  });

  it("never returns a negative price", () => {
    expect(computeDiscountedPriceCents(2800, 150)).toBe(0);
  });
});

describe("transitionCustomizablePrice", () => {
  it("turns pay-what-you-want on when the price becomes 0", () => {
    expect(transitionCustomizablePrice(500, 0, false, false)).toBe(true);
    expect(transitionCustomizablePrice(0, 0, true, true)).toBe(true);
  });

  it("restores the prior PWYW state when the price leaves 0", () => {
    expect(transitionCustomizablePrice(0, 500, true, false)).toBe(false);
  });

  it("keeps a deliberate pay-what-you-want across a temporary $0 dip", () => {
    // 500 (PWYW on) -> 0 (forced PWYW) -> 500: prior deliberate PWYW survives the dip.
    expect(transitionCustomizablePrice(0, 500, true, true)).toBe(true);
  });

  it("keeps a deliberate pay-what-you-want across nonzero price edits", () => {
    expect(transitionCustomizablePrice(500, 600, true, true)).toBe(true);
  });

  it("does not enable pay-what-you-want on a nonzero edit of a fixed-price bundle", () => {
    expect(transitionCustomizablePrice(500, 600, false, false)).toBe(false);
  });
});
