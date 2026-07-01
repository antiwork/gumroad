import { describe, expect, it } from "vitest";

import type { SurchargesResponse } from "$app/data/customer_surcharge";

import {
  getCheckoutBuyerCurrencyDisplay,
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
    expires_at: "2026-07-01T00:00:00Z",
  },
  ...overrides,
});

describe("getCheckoutBuyerCurrencyDisplay", () => {
  it("uses the locked surcharge quote as the checkout display rate", () => {
    const display = getCheckoutBuyerCurrencyDisplay(surcharges());

    if (!display) throw new Error("Expected a buyer-currency display");
    expect(display).toEqual({ currencyCode: "cad", rate: 1.25 });
    expect(toBuyerCurrencyCents(1_000, display)).toBe(1_250);
    expect(toCanonicalCents(1_250, display)).toBe(1_000);
  });

  it("does not use buyer-currency display when there is no quote", () => {
    expect(getCheckoutBuyerCurrencyDisplay(surcharges({ buyer_currency_quote: null }))).toBeNull();
  });
});
