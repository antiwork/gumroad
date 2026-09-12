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

  it("includes Nordic, Mexican and the eight new buyer currencies with 100 subunits and configured floors", () => {
    const added = [
      { code: "sek", min: 999, longSymbol: "kr", displayFormat: "kr (Swedish krona)" },
      { code: "nok", min: 949, longSymbol: "kr", displayFormat: "kr (Norwegian krone)" },
      { code: "dkk", min: 649, longSymbol: "kr", displayFormat: "kr (Danish krone)" },
      { code: "mxn", min: 1699, longSymbol: "MX$", displayFormat: "MX$ (Mexican peso)" },
      { code: "sar", min: 372, longSymbol: "SAR", displayFormat: "SAR (Saudi riyal)" },
      { code: "aed", min: 364, longSymbol: "AED", displayFormat: "AED (UAE dirham)" },
      { code: "try", min: 4812, longSymbol: "₺", displayFormat: "₺ (Turkish lira)" },
      { code: "cop", min: 307474, longSymbol: "COL$", displayFormat: "COL$ (Colombian peso)" },
      { code: "ron", min: 449, longSymbol: "lei", displayFormat: "lei (Romanian leu)" },
      { code: "thb", min: 3270, longSymbol: "฿", displayFormat: "฿ (Thai baht)" },
      { code: "myr", min: 403, longSymbol: "RM", displayFormat: "RM (Malaysian ringgit)" },
      { code: "idr", min: 1743007, longSymbol: "Rp", displayFormat: "Rp (Indonesian rupiah)" },
    ] as const;

    for (const { code, min, longSymbol, displayFormat } of added) {
      expect(currencyCodeList).toContain(code);
      expect(getIsSingleUnitCurrency(code)).toBe(false);
      expect(getMinPriceCents(code)).toBe(min);
      expect(findCurrencyByCode(code).longSymbol).toBe(longSymbol);
      expect(findCurrencyByCode(code).displayFormat).toBe(displayFormat);
    }

    expect(findCurrencyByCode("mxn").shortSymbol).toBe("$");
    expect(findCurrencyByCode("cop").shortSymbol).toBe("$");
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
});
