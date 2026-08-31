import { describe, expect, it } from "vitest";

import { hasPaidVariantPricing, reconcileCustomizablePrice } from "$app/components/ProductEdit/state";

const product = ({
  priceCents,
  customizablePrice,
  variantPriceCents = [],
  nativeType = "digital",
}: {
  priceCents: number;
  customizablePrice: boolean;
  variantPriceCents?: number[];
  nativeType?: "digital" | "coffee" | "membership";
}) => ({
  native_type: nativeType,
  price_cents: priceCents,
  customizable_price: customizablePrice,
  variants: variantPriceCents.map((price_difference_cents) => ({ price_difference_cents })),
});

describe("hasPaidVariantPricing", () => {
  it("is true only when some variant has a positive price difference", () => {
    expect(hasPaidVariantPricing({ variants: [] })).toBe(false);
    expect(hasPaidVariantPricing({ variants: [{ price_difference_cents: 0 }, { price_difference_cents: null }] })).toBe(
      false,
    );
    expect(hasPaidVariantPricing({ variants: [{ price_difference_cents: 0 }, { price_difference_cents: 1500 }] })).toBe(
      true,
    );
  });
});

describe("reconcileCustomizablePrice", () => {
  it("forces PWYW off on a $0 base with paid variant pricing", () => {
    expect(
      reconcileCustomizablePrice(
        product({ priceCents: 0, customizablePrice: true, variantPriceCents: [1500] }),
        0,
        true,
      ),
    ).toBe(false);
  });

  it("forces PWYW on for a $0 base without paid variant pricing", () => {
    expect(reconcileCustomizablePrice(product({ priceCents: 0, customizablePrice: false }), 1500, false)).toBe(true);
  });

  it("turns PWYW back on when a $0 product loses its last paid variant", () => {
    expect(reconcileCustomizablePrice(product({ priceCents: 0, customizablePrice: false }), 0, false)).toBe(true);
  });

  it("keeps a forced-on flag when the price leaves $0 without paid variants", () => {
    expect(reconcileCustomizablePrice(product({ priceCents: 1000, customizablePrice: true }), 0, false)).toBe(true);
  });

  it("restores the prior choice when the price leaves $0 with paid variants", () => {
    expect(
      reconcileCustomizablePrice(
        product({ priceCents: 1500, customizablePrice: false, variantPriceCents: [1500] }),
        0,
        true,
      ),
    ).toBe(true);
  });

  it("keeps the current choice at a nonzero price", () => {
    expect(
      reconcileCustomizablePrice(
        product({ priceCents: 1500, customizablePrice: true, variantPriceCents: [1500] }),
        1000,
        false,
      ),
    ).toBe(true);
  });

  it("leaves coffee and membership products alone", () => {
    for (const nativeType of ["coffee", "membership"] as const) {
      expect(
        reconcileCustomizablePrice(
          product({ priceCents: 0, customizablePrice: true, variantPriceCents: [500], nativeType }),
          0,
          false,
        ),
      ).toBe(true);
    }
  });
});
