import { describe, expect, it } from "vitest";

import { cast } from "$app/utils/cast";

import { hasLiveBuildFile, hasPaidVariantPricing, reconcileCustomizablePrice } from "$app/components/ProductEdit/state";

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
  it("keeps the seller's flag on a $0 base with paid variant pricing", () => {
    const paidVariants = [1500];
    expect(
      reconcileCustomizablePrice(product({ priceCents: 0, customizablePrice: true, variantPriceCents: paidVariants })),
    ).toBe(true);
    expect(
      reconcileCustomizablePrice(product({ priceCents: 0, customizablePrice: false, variantPriceCents: paidVariants })),
    ).toBe(false);
  });

  it("forces PWYW on for a $0 base without paid variant pricing", () => {
    expect(reconcileCustomizablePrice(product({ priceCents: 0, customizablePrice: false }))).toBe(true);
  });

  it("keeps a forced-on flag when the price leaves $0 without paid variants", () => {
    expect(reconcileCustomizablePrice(product({ priceCents: 1000, customizablePrice: true }))).toBe(true);
  });

  it("keeps the current choice at a nonzero price", () => {
    expect(
      reconcileCustomizablePrice(product({ priceCents: 1500, customizablePrice: true, variantPriceCents: [1500] })),
    ).toBe(true);
  });

  it("leaves coffee and membership products alone", () => {
    for (const nativeType of ["coffee", "membership"] as const) {
      expect(
        reconcileCustomizablePrice(
          product({ priceCents: 0, customizablePrice: true, variantPriceCents: [500], nativeType }),
        ),
      ).toBe(true);
    }
  });
});

describe("hasLiveBuildFile", () => {
  const liveFile = { id: "live-file", web_build: { number: 2, status: "live" } };
  const withContent = (ids: string[], variantIds: string[] = []) =>
    cast<Parameters<typeof hasLiveBuildFile>[0]>({
      files: [{ id: "other-file", web_build: null }, liveFile],
      rich_content: [{ description: { content: ids.map((id) => ({ type: "fileEmbed", attrs: { id } })) } }],
      variants: [{ rich_content: [{ description: { content: variantIds.map((id) => ({ attrs: { id } })) } }] }],
    });

  it("is true while the live build's file is embedded in any page", () => {
    expect(hasLiveBuildFile(withContent(["live-file"]))).toBe(true);
    expect(hasLiveBuildFile(withContent([], ["live-file"]))).toBe(true);
  });

  it("is false once the row is removed, or when no build is live", () => {
    expect(hasLiveBuildFile(withContent(["other-file"]))).toBe(false);
    expect(hasLiveBuildFile(cast({ files: [{ id: "x", web_build: null }], rich_content: [], variants: [] }))).toBe(
      false,
    );
  });
});
