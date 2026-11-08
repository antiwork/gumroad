import { describe, it, expect } from "vitest";

import {
  formatPrice,
  parseUnitStringToPriceCents,
  priceCommaHint,
  sanitizePriceRangeInput,
  priceCentsToUnit,
  priceUnitToCents,
} from "$app/utils/price";

describe("priceCentsToUnit", () => {
  it("converts cents to a two-decimal unit amount for a regular currency", () => {
    expect(priceCentsToUnit(123, false)).toBe(1.23);
  });

  it("treats cents as units for a single-unit currency like JPY", () => {
    expect(priceCentsToUnit(500, true)).toBe(500);
  });
});

describe("priceUnitToCents", () => {
  it("converts a unit amount to cents for a regular currency", () => {
    expect(priceUnitToCents(1.23, false)).toBe(123);
  });

  it("rounds a fractional cent boundary to the nearest cent", () => {
    // 1.005 * 100 = 100.49999999999999 in IEEE-754; preciseAmount rounds via toFixed(0)
    expect(priceUnitToCents(1.005, false)).toBe(100);
  });
});

describe("formatPrice", () => {
  it("formats a two-decimal USD amount with the currency symbol", () => {
    expect(formatPrice("$", 1.23, 2, { noCentsIfWhole: false })).toBe("$1.23");
  });

  it("drops the cents on a whole amount when noCentsIfWhole is set", () => {
    expect(formatPrice("$", 5, 2, { noCentsIfWhole: true })).toBe("$5");
  });

  it("keeps the cents on a whole amount when noCentsIfWhole is false", () => {
    expect(formatPrice("$", 5, 2, { noCentsIfWhole: false })).toBe("$5.00");
  });
});

describe("parseUnitStringToPriceCents", () => {
  it("parses a two-decimal USD string into cents", () => {
    expect(parseUnitStringToPriceCents("1.23", false)).toBe(123);
  });

  it("parses a single-unit currency string without applying a 100x factor", () => {
    expect(parseUnitStringToPriceCents("500", true)).toBe(500);
  });

  it("strips a currency symbol before parsing", () => {
    expect(parseUnitStringToPriceCents("$1.50", false)).toBe(150);
  });

  it("returns NaN for non-numeric input that strips to an empty string", () => {
    // Characterization: "abc" strips to "", which parseFloat turns into NaN
    // rather than the null path used for locale-ambiguous input. Pinned to
    // catch any future change to this edge behavior.
    expect(parseUnitStringToPriceCents("abc", false)).toBeNaN();
  });

  it("returns null for a null input", () => {
    expect(parseUnitStringToPriceCents(null, false)).toBeNull();
  });
});

describe("sanitizePriceRangeInput", () => {
  it("keeps a thousands comma so the server reads 7,900 as grouping", () => {
    expect(sanitizePriceRangeInput("7,900")).toBe("7,900");
  });

  it("keeps a Euro decimal comma", () => {
    expect(sanitizePriceRangeInput("7,90")).toBe("7,90");
  });

  it("strips non-amount characters and extra decimal points", () => {
    expect(sanitizePriceRangeInput("₩1.2.3abc")).toBe("1.23");
  });
});

describe("priceCommaHint", () => {
  it("names both readings the server gives a typed comma", () => {
    expect(priceCommaHint(false)).toBe("Use a comma for thousands (7,900) or for cents (7,90).");
  });

  it("offers only thousands for a currency without minor units", () => {
    expect(priceCommaHint(true)).toBe("Use a comma for thousands (7,900).");
  });
});
