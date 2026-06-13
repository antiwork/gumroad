import { describe, it, expect } from "vitest";

import { currencyCodeList, findCurrencyByCode, getIsSingleUnitCurrency, getMinPriceCents } from "$app/utils/currency";

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
});
