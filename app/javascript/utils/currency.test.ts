import { describe, it, expect } from "vitest";

import {
  currencyCodeList,
  findCurrencyByCode,
  formatMinorUnitPriceWithIntl,
  getIsSingleUnitCurrency,
  getMinPriceCents,
} from "$app/utils/currency";

describe("findCurrencyByCode", () => {
  it("returns the USD spec with a dollar symbol and two-decimal (non-single-unit) handling", () => {
    const usd = findCurrencyByCode("usd");
    expect(usd.code).toBe("usd");
    expect(usd.longSymbol).toBe("$");
    expect(usd.isSingleUnit).toBe(false);
  });

  it("marks JPY as a single-unit currency", () => {
    const jpy = findCurrencyByCode("jpy");
    expect(jpy.isSingleUnit).toBe(true);
    expect(jpy.longSymbol).toBe("¥");
  });

  it("defaults the short symbol to the long symbol when no short symbol is configured", () => {
    const usd = findCurrencyByCode("usd");
    expect(usd.shortSymbol).toBe(usd.longSymbol);
  });

  it("uses the spelled-out name for GBP, same pattern as USD", () => {
    expect(findCurrencyByCode("gbp").displayFormat).toBe("£ (British Pounds)");
    expect(findCurrencyByCode("usd").displayFormat).toBe("$ (US Dollars)");
  });
});

describe("getIsSingleUnitCurrency", () => {
  it("reports false for USD and true for JPY", () => {
    expect(getIsSingleUnitCurrency("usd")).toBe(false);
    expect(getIsSingleUnitCurrency("jpy")).toBe(true);
  });
});

describe("getMinPriceCents", () => {
  it("returns the configured minimum price for USD", () => {
    expect(getMinPriceCents("usd")).toBe(99);
  });
});

describe("currencyCodeList", () => {
  it("includes usd, pinning the config/currencies.json wiring through the JSON import", () => {
    expect(currencyCodeList).toContain("usd");
  });

  it("includes Nordic and Mexican currencies with 100 subunits and configured floors", () => {
    const added = [
      { code: "sek", min: 999, longSymbol: "kr", displayFormat: "kr (Swedish Krona)" },
      { code: "nok", min: 949, longSymbol: "kr", displayFormat: "kr (Norwegian Krone)" },
      { code: "dkk", min: 649, longSymbol: "kr", displayFormat: "kr (Danish Krone)" },
      { code: "mxn", min: 1699, longSymbol: "MX$", displayFormat: "MX$ (Mexican Peso)" },
    ] as const;

    for (const { code, min, longSymbol, displayFormat } of added) {
      expect(currencyCodeList).toContain(code);
      expect(getIsSingleUnitCurrency(code)).toBe(false);
      expect(getMinPriceCents(code)).toBe(min);
      expect(findCurrencyByCode(code).longSymbol).toBe(longSymbol);
      expect(findCurrencyByCode(code).displayFormat).toBe(displayFormat);
    }

    expect(findCurrencyByCode("mxn").shortSymbol).toBe("$");
    expect(findCurrencyByCode("sek").shortSymbol).toBe("kr");
  });
});

describe("formatMinorUnitPriceWithIntl", () => {
  it("hides cents on whole amounts and keeps them on fractional ones", () => {
    expect(formatMinorUnitPriceWithIntl("gbp", 0, 100)).toBe("£0");
    expect(formatMinorUnitPriceWithIntl("gbp", 800, 100)).toBe("£8");
    expect(formatMinorUnitPriceWithIntl("gbp", 749, 100)).toBe("£7.49");
  });

  it("never shows decimals for a 1-subunit currency", () => {
    expect(formatMinorUnitPriceWithIntl("jpy", 1441, 1)).toBe("¥1,441");
  });

  it("uses the currency convention when an internal 100-subunit amount is fractional", () => {
    expect(formatMinorUnitPriceWithIntl("krw", 1_343_250, 100)).toBe("₩13,433");
  });

  it("shows cents on a whole amount when the caller is matching a column that has them", () => {
    expect(formatMinorUnitPriceWithIntl("usd", 1_000, 100, { noCentsIfWhole: false })).toBe("$10.00");
    expect(formatMinorUnitPriceWithIntl("usd", 1_000, 100)).toBe("$10");
  });

  it("keeps a zero-decimal currency whole even when the caller asks for cents", () => {
    expect(formatMinorUnitPriceWithIntl("krw", 1_000_000, 100, { noCentsIfWhole: false })).toBe("₩10,000");
  });
});
