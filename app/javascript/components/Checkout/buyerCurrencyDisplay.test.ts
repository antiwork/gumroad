import { describe, expect, it } from "vitest";

import type { SurchargesResponse } from "$app/data/customer_surcharge";

import {
  formatCheckoutPrice,
  getCheckoutBuyerCurrencyDisplay,
  getCheckoutBuyerCurrencyQuoteToken,
  getCheckoutPresentmentAmounts,
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
    line_allocations: [
      { permalink: "prod", price_cents: 1_250, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 1_250 },
    ],
  },
  ...overrides,
});

const cartOptions = { cartPermalinks: ["prod"] };

describe("getCheckoutBuyerCurrencyDisplay", () => {
  it("uses the locked surcharge quote as the checkout display rate", () => {
    const display = getCheckoutBuyerCurrencyDisplay(surcharges(), cartOptions);

    if (!display) throw new Error("Expected a buyer-currency display");
    expect(display).toEqual({
      currencyCode: "cad",
      rate: 1.25,
      subunitToUnit: 100,
      presentmentTotalCents: 1_250,
      lineAllocations: [
        { permalink: "prod", price_cents: 1_250, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 1_250 },
      ],
    });
    expect(toBuyerCurrencyCents(1_000, display)).toBe(1_250);
    expect(toCanonicalCents(1_250, display)).toBe(1_000);
  });

  it("does not use buyer-currency display when there is no quote", () => {
    expect(getCheckoutBuyerCurrencyDisplay(surcharges({ buyer_currency_quote: null }), cartOptions)).toBeNull();
  });

  it("does not use buyer-currency display when the checkout will save the card", () => {
    // Saving a card charges through the canonical path, so displaying locked local-currency
    // totals would show an amount the buyer is never charged.
    expect(getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, willSaveCard: true })).toBeNull();
    expect(getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, willSaveCard: false })).not.toBeNull();
  });

  it("does not use buyer-currency display while a non-card payment method is selected", () => {
    // PayPal and wallet charges can only be canonical USD, so the cart must show the USD
    // totals those methods will actually charge — and withhold the quote token, which would
    // otherwise dead-end the charge (it fails closed on a token it cannot present).
    expect(getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, paymentMethod: "paypal" })).toBeNull();
    expect(
      getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, paymentMethod: "stripePaymentRequest" }),
    ).toBeNull();
    expect(getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, paymentMethod: "card" })).not.toBeNull();
  });

  it("does not use buyer-currency display when the allocation is missing or belongs to another cart", () => {
    const responseWithoutAllocations = surcharges();
    if (responseWithoutAllocations.buyer_currency_quote) {
      delete responseWithoutAllocations.buyer_currency_quote.line_allocations;
    }

    expect(getCheckoutBuyerCurrencyDisplay(responseWithoutAllocations, cartOptions)).toBeNull();
    expect(getCheckoutBuyerCurrencyDisplay(surcharges(), { cartPermalinks: ["other"] })).toBeNull();
  });
});

describe("getCheckoutPresentmentAmounts", () => {
  // The PR's odd-cent example: 334 + 667 cents at a 1.25 rate. Converting each line
  // independently renders 418 + 834 = 1252, one cent above the locked/charged total of
  // 1251; the server allocation is [417, 834].
  const oddCentDisplay = () =>
    getCheckoutBuyerCurrencyDisplay(
      surcharges({
        subtotal: 1_001,
        buyer_currency_quote: {
          token: "quote-token",
          currency: "cad",
          canonical_total_cents: 1_001,
          presentment_total_cents: 1_251,
          rate: 1.25,
          subunit_to_unit: 100,
          expires_at: "2026-07-01T00:00:00Z",
          line_allocations: [
            { permalink: "first", price_cents: 417, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 417 },
            { permalink: "second", price_cents: 834, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 834 },
          ],
        },
      }),
      { cartPermalinks: ["first", "second"] },
    );

  it("renders the server's allocated line amounts so the visible lines sum exactly to the locked total", () => {
    const amounts = getCheckoutPresentmentAmounts(oddCentDisplay(), [
      { permalink: "first", discountCents: 0 },
      { permalink: "second", discountCents: 0 },
    ]);

    if (!amounts) throw new Error("Expected presentment amounts");
    expect(amounts.linePriceCents).toEqual([417, 834]);
    expect(amounts.totalCents).toBe(1_251);
    // The independently rounded conversions (418 + 834) would NOT reconcile; the allocated
    // amounts must.
    expect(
      amounts.linePriceCents.reduce((sum, cents) => sum + cents, 0) -
        amounts.discountCents +
        amounts.taxCents +
        amounts.shippingCents +
        amounts.tipCents,
    ).toBe(amounts.totalCents);
    expect(amounts.subtotalCents).toBe(1_251);
  });

  it("reconciles every visible row (lines, discount, tip, tax, shipping) to the locked total", () => {
    const display = getCheckoutBuyerCurrencyDisplay(
      surcharges({
        buyer_currency_quote: {
          token: "quote-token",
          currency: "cad",
          canonical_total_cents: 1_850,
          presentment_total_cents: 2_313,
          rate: 1.25,
          subunit_to_unit: 100,
          expires_at: "2026-07-01T00:00:00Z",
          line_allocations: [
            {
              permalink: "first",
              price_cents: 1_250,
              tip_cents: 125,
              tax_cents: 63,
              shipping_cents: 250,
              total_cents: 1_688,
            },
            { permalink: "second", price_cents: 625, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 625 },
          ],
        },
      }),
      { cartPermalinks: ["first", "second"] },
    );

    // The first line is displayed pre-discount (the discount has its own row), so its
    // visible price is the allocated charged amount plus the converted 100-cent discount.
    const amounts = getCheckoutPresentmentAmounts(display, [
      { permalink: "first", discountCents: 100 },
      { permalink: "second", discountCents: 0 },
    ]);

    if (!amounts) throw new Error("Expected presentment amounts");
    expect(amounts.linePriceCents).toEqual([1_375, 625]);
    expect(amounts.discountCents).toBe(125);
    expect(amounts.tipCents).toBe(125);
    expect(amounts.taxCents).toBe(63);
    expect(amounts.shippingCents).toBe(250);
    expect(amounts.subtotalCents).toBe(2_125);
    expect(amounts.subtotalCents - amounts.discountCents + amounts.taxCents + amounts.shippingCents).toBe(
      amounts.totalCents,
    );
  });

  it("returns null while the allocation does not line up with the cart lines", () => {
    // Defense in depth for a caller holding a display derived from an earlier cart.
    expect(getCheckoutPresentmentAmounts(oddCentDisplay(), [{ permalink: "first", discountCents: 0 }])).toBeNull();
    expect(
      getCheckoutPresentmentAmounts(oddCentDisplay(), [
        { permalink: "first", discountCents: 0 },
        { permalink: "other", discountCents: 0 },
      ]),
    ).toBeNull();
    expect(getCheckoutPresentmentAmounts(null, [])).toBeNull();
  });
});

describe("getCheckoutBuyerCurrencyQuoteToken", () => {
  it("sends the locked quote token only when buyer-currency totals are displayed", () => {
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges(), cartOptions)).toBe("quote-token");
    // Saving the card charges canonically, so the token must be withheld with the display.
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges(), { ...cartOptions, willSaveCard: true })).toBeNull();
    // A non-card method (PayPal) also charges canonically; sending the token with it would
    // make the charge fail closed on every attempt instead of completing in USD.
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges(), { ...cartOptions, paymentMethod: "paypal" })).toBeNull();
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges({ buyer_currency_quote: null }), cartOptions)).toBeNull();
    expect(getCheckoutBuyerCurrencyQuoteToken(null, cartOptions)).toBeNull();
  });

  it("withholds the token when the quote allocation cannot be displayed", () => {
    const response = surcharges();
    if (response.buyer_currency_quote) delete response.buyer_currency_quote.line_allocations;

    expect(getCheckoutBuyerCurrencyQuoteToken(response, cartOptions)).toBeNull();
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges(), { cartPermalinks: ["other"] })).toBeNull();
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
