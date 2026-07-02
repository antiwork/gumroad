import { describe, expect, it } from "vitest";

import type { SurchargesResponse } from "$app/data/customer_surcharge";

import {
  formatCheckoutPrice,
  getCheckoutBuyerCurrencyDisplay,
  getCheckoutBuyerCurrencyQuoteToken,
  toBuyerCurrencyCents,
  toCanonicalCents,
} from "$app/components/Checkout/buyerCurrencyDisplay";

const surcharges = (overrides: Partial<SurchargesResponse> = {}): SurchargesResponse => ({
  vat_id_valid: false,
  has_vat_id_input: false,
  shipping_rate_cents: 0,
  tax_cents: 0,
  tax_included_cents: 0,
  subtotal: 1_000,
  buyer_currency_quote: {
    token: "quote-token",
    currency: "cad",
    canonical_total_cents: 1_000,
    presentment_total_cents: 1_250,
    rate: 1.25,
    subunit_to_unit: 100,
    expires_at: "2026-07-01T00:00:00Z",
  },
  ...overrides,
});

describe("getCheckoutBuyerCurrencyDisplay", () => {
  it("uses the locked surcharge quote as the checkout display rate", () => {
    const display = getCheckoutBuyerCurrencyDisplay(surcharges());

    if (!display) throw new Error("Expected a buyer-currency display");
    expect(display).toEqual({ currencyCode: "cad", rate: 1.25, subunitToUnit: 100 });
    expect(toBuyerCurrencyCents(1_000, display)).toBe(1_250);
    expect(toCanonicalCents(1_250, display)).toBe(1_000);
  });

  it("does not use buyer-currency display when there is no quote", () => {
    expect(getCheckoutBuyerCurrencyDisplay(surcharges({ buyer_currency_quote: null }))).toBeNull();
  });

  it("does not use buyer-currency display when the checkout will save the card", () => {
    // Saving a card charges through the canonical path, so displaying locked local-currency
    // totals would show an amount the buyer is never charged.
    expect(getCheckoutBuyerCurrencyDisplay(surcharges(), { willSaveCard: true })).toBeNull();
    expect(getCheckoutBuyerCurrencyDisplay(surcharges(), { willSaveCard: false })).not.toBeNull();
  });
});

describe("getCheckoutBuyerCurrencyQuoteToken", () => {
  it("sends the locked quote token only when buyer-currency totals are displayed", () => {
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges())).toBe("quote-token");
    // Saving the card charges canonically, so the token must be withheld with the display.
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges(), { willSaveCard: true })).toBeNull();
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges({ buyer_currency_quote: null }))).toBeNull();
    expect(getCheckoutBuyerCurrencyQuoteToken(null)).toBeNull();
  });
});

describe("formatCheckoutPrice", () => {
  it("formats buyer-currency amounts using the backend's minor-unit scale", () => {
    expect(formatCheckoutPrice(1_000, { currencyCode: "cad", rate: 1.25, subunitToUnit: 100 })).toBe("CA$12.50");
  });

  it("formats zero-decimal buyer currencies as whole units", () => {
    expect(formatCheckoutPrice(1_000, { currencyCode: "jpy", rate: 1.441, subunitToUnit: 1 })).toBe("¥1,441");
  });

  it("does not divide by the heuristic subunit when the backend scale is 1", () => {
    // Guards against falling back to the currencies.json single_unit heuristic, which would
    // divide non-flagged currencies by 100 regardless of how the backend denominates them.
    expect(formatCheckoutPrice(1_441, { currencyCode: "jpy", rate: 1, subunitToUnit: 1 })).toBe("¥1,441");
  });

  it("formats canonical USD when no buyer-currency display exists", () => {
    expect(formatCheckoutPrice(1_000, null)).toBe("US$10");
  });
});
