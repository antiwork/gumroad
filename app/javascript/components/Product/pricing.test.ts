import { describe, expect, it } from "vitest";

import { getBundleComparisonPriceCents } from "$app/components/Product/pricing";

// A bundle of ten $35 products, each pinned to a free child variant: what the
// buyer would pay buying them one by one is $350.
const bundle = { bundle_products: Array.from({ length: 10 }, () => ({ price: 3500 })) };

describe("getBundleComparisonPriceCents", () => {
  it("has no comparison price for a product that is not a bundle", () => {
    expect(getBundleComparisonPriceCents({ bundle_products: [] }, null)).toBeNull();
  });

  it("compares against the sum of what the bundled products cost separately when the bundle has no tiers", () => {
    expect(getBundleComparisonPriceCents(bundle, null)).toBe(35000);
  });

  it("compares against the standalone sum on a tier that adds nothing to the price", () => {
    expect(getBundleComparisonPriceCents(bundle, { price_difference_cents: 0 })).toBe(35000);
  });

  it("treats a tier with no price difference set as adding nothing", () => {
    expect(getBundleComparisonPriceCents(bundle, { price_difference_cents: null })).toBe(35000);
  });

  // The bug this covers: the bundled products are pinned to one child variant, so
  // the standalone sum stays at $350 no matter which bundle tier is picked. On a
  // +$150 tier the buyer pays $299 against a "$350" that describes a cheaper
  // product, understating the saving. Showing nothing is better than showing that.
  it("has no comparison price on a tier that costs extra", () => {
    expect(getBundleComparisonPriceCents(bundle, { price_difference_cents: 15000 })).toBeNull();
    expect(getBundleComparisonPriceCents(bundle, { price_difference_cents: 75000 })).toBeNull();
  });
});
