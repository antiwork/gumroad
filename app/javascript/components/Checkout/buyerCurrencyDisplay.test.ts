import { describe, expect, it } from "vitest";

import type { SurchargesResponse } from "$app/data/customer_surcharge";
import type { CurrencyCode } from "$app/utils/currency";

import {
  formatCheckoutPrice,
  formatPresentmentCents,
  getCheckoutBuyerCurrencyDisplay,
  getCheckoutBuyerCurrencyQuoteToken,
  getCheckoutListedCurrencyAmounts,
  getCheckoutListedCurrencyDisplay,
  getCheckoutPresentmentAmounts,
  toBuyerCurrencyCents,
  toCanonicalCents,
} from "$app/components/Checkout/buyerCurrencyDisplay";
import type { CheckoutPaymentConfig } from "$app/components/Checkout/payment";

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
    charge_presentment_total_cents: 500,
    rate: 1.25,
    subunit_to_unit: 100,
    expires_at: "2026-07-01T00:00:00Z",
    line_allocations: [
      { permalink: "prod", price_cents: 1_250, tip_cents: 0, tax_cents: 0, shipping_cents: 0, total_cents: 1_250 },
    ],
  },
  ...overrides,
});

const cartOptions = { cartPermalinks: ["prod"], paymentElementType: "card" };

describe("getCheckoutBuyerCurrencyDisplay", () => {
  it("uses the locked surcharge quote as the checkout display rate", () => {
    const display = getCheckoutBuyerCurrencyDisplay(surcharges(), cartOptions);

    if (!display) throw new Error("Expected a buyer-currency display");
    expect(display).toEqual({
      currencyCode: "cad",
      rate: 1.25,
      subunitToUnit: 100,
      presentmentTotalCents: 1_250,
      chargePresentmentTotalCents: 500,
      futureInstallmentsPresentmentTotalCents: null,
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

  it("does not use buyer-currency display when Apple Pay or Google Pay is selected in the Payment Element", () => {
    expect(
      getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, paymentElementType: "apple_pay" }),
    ).toBeNull();
    expect(
      getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, paymentElementType: "google_pay" }),
    ).toBeNull();
    expect(
      getCheckoutBuyerCurrencyDisplay(surcharges(), { ...cartOptions, paymentElementType: "card" }),
    ).not.toBeNull();
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
    expect(
      getCheckoutBuyerCurrencyQuoteToken(surcharges(), { ...cartOptions, paymentElementType: "apple_pay" }),
    ).toBeNull();
    expect(
      getCheckoutBuyerCurrencyQuoteToken(surcharges(), { ...cartOptions, paymentElementType: "google_pay" }),
    ).toBeNull();
    expect(getCheckoutBuyerCurrencyQuoteToken(surcharges({ buyer_currency_quote: null }), cartOptions)).toBeNull();
    expect(getCheckoutBuyerCurrencyQuoteToken(null, cartOptions)).toBeNull();
  });

  it("withholds the token when the quote allocation cannot be displayed", () => {
    const response = surcharges();
    if (response.buyer_currency_quote) delete response.buyer_currency_quote.line_allocations;

    expect(getCheckoutBuyerCurrencyQuoteToken(response, cartOptions)).toBeNull();
    expect(
      getCheckoutBuyerCurrencyQuoteToken(surcharges(), { cartPermalinks: ["other"], paymentElementType: "card" }),
    ).toBeNull();
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

  it("drops .00 on whole buyer-currency amounts the same way USD does", () => {
    expect(formatCheckoutPrice(0, { currencyCode: "gbp", rate: 1, subunitToUnit: 100 })).toBe("£0");
    expect(formatCheckoutPrice(1_000, { currencyCode: "gbp", rate: 0.8, subunitToUnit: 100 })).toBe("£8");
  });

  it("keeps two decimals on fractional buyer-currency amounts", () => {
    expect(formatCheckoutPrice(1_000, { currencyCode: "gbp", rate: 0.749, subunitToUnit: 100 })).toBe("£7.49");
  });
});

describe("getCheckoutListedCurrencyDisplay", () => {
  type ClientConfirmPayment = Extract<CheckoutPaymentConfig, { integration: "payment_element_client_confirm" }>;

  // A BRL product paid with Pix: the element mounts in BRL, the charge bills the listed
  // R$49.90 directly, and there is no FX quote anywhere in the flow.
  const listedCurrencyPayment = (
    listedCurrencyDisplay: { currency: string; subunit_to_unit: number } | null = {
      currency: "brl",
      subunit_to_unit: 100,
    },
  ): ClientConfirmPayment => ({
    integration: "payment_element_client_confirm",
    fallback_reason: null,
    recurring_upi_registration: false,
    disable_wallets: true,
    request_apple_pay_merchant_tokens: false,
    payment_element_wallets: false,
    flat_payment_methods: true,
    elements_options: {
      stripe_elements_mode: "payment",
      currency: "brl",
      buyer_currency_presentment: false,
      presentment_amount_cents: 4_990,
      listed_currency_display: listedCurrencyDisplay,
      payment_method_types: ["card", "pix"],
      payment_method_list_token: null,
      stripe_link_enabled: false,
      stripe_connect_account_id: null,
    },
  });

  const brlCartItems = (overrides: { currencyCode?: CurrencyCode; exchangeRate?: number; creatorId?: string } = {}) => [
    {
      product: {
        currency_code: overrides.currencyCode ?? "brl",
        exchange_rate: overrides.exchangeRate ?? 5.45,
        creator: { id: overrides.creatorId ?? "seller-a" },
      },
    },
  ];

  const recurringUpiPayment = (): ClientConfirmPayment => ({
    ...listedCurrencyPayment({ currency: "inr", subunit_to_unit: 100 }),
    recurring_upi_registration: true,
    elements_options: {
      ...listedCurrencyPayment().elements_options,
      currency: "inr",
      presentment_amount_cents: 73_000,
      listed_currency_display: { currency: "inr", subunit_to_unit: 100 },
      payment_method_types: ["card", "upi"],
    },
  });

  const directListedCardPayment = (): CheckoutPaymentConfig => {
    const payment = listedCurrencyPayment();
    if (payment.integration !== "payment_element_client_confirm") throw new Error("unexpected payment config");
    return {
      ...payment,
      elements_options: { ...payment.elements_options, direct_listed_card: true },
    };
  };

  it("renders the listed currency for a method-forced cart priced in that currency", () => {
    const listed = getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), brlCartItems());

    expect(listed).toEqual({ currencyCode: "brl", rate: 5.45, subunitToUnit: 100 });
  });

  it("falls back to USD for tip or shipping shapes excluded from the direct-listed card lane", () => {
    expect(getCheckoutListedCurrencyDisplay(directListedCardPayment(), brlCartItems(), { hasTip: true })).toBeNull();
    expect(
      getCheckoutListedCurrencyDisplay(directListedCardPayment(), brlCartItems(), { hasShipping: true }),
    ).toBeNull();
    expect(getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), brlCartItems(), { hasTip: true })).not.toBeNull();
  });

  it("stays in canonical USD when the server did not choose the listed-currency lane", () => {
    expect(getCheckoutListedCurrencyDisplay(listedCurrencyPayment(null), brlCartItems())).toBeNull();
  });

  it("renders the listed currency for a multi-item cart uniformly priced in it", () => {
    expect(getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), [...brlCartItems(), ...brlCartItems()])).toEqual({
      currencyCode: "brl",
      rate: 5.45,
      subunitToUnit: 100,
    });
  });

  it("stays in canonical USD when same-currency items come from two sellers", () => {
    expect(
      getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), [
        ...brlCartItems(),
        ...brlCartItems({ creatorId: "seller-b" }),
      ]),
    ).toBeNull();
  });

  it("stays in canonical USD for an empty cart or one mixing pricing currencies", () => {
    expect(getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), [])).toBeNull();
    // One USD line beside a BRL line means the server mounted the canonical USD element, so
    // displaying the listed currency would lie.
    expect(
      getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), [
        ...brlCartItems(),
        ...brlCartItems({ currencyCode: "usd" }),
      ]),
    ).toBeNull();
  });

  it("stays in canonical USD when items disagree on the exchange rate", () => {
    // A partial rate reload could leave same-currency items on split rates; converting shared
    // USD rows (tax, shipping) with either rate could disagree with the charge.
    expect(
      getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), [
        ...brlCartItems(),
        ...brlCartItems({ exchangeRate: 5.5 }),
      ]),
    ).toBeNull();
  });

  it("stays in canonical USD when the cart's product is not priced in the element's currency", () => {
    expect(getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), brlCartItems({ currencyCode: "usd" }))).toBeNull();
  });

  it("stays in canonical USD when the product has no usable exchange rate", () => {
    // A zero rate would convert every USD-side row (tax, shipping) to zero.
    expect(getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), brlCartItems({ exchangeRate: 0 }))).toBeNull();
  });

  // Only a new card confirmed through the Payment Element reaches Charge::MethodForcedPresentment.
  // Every other selection charges canonical USD, so the summary must keep showing USD for it.
  it("stays in canonical USD while the buyer pays with a card already on file", () => {
    // This is the DEFAULT for any returning buyer, so getting it wrong would mis-display the
    // common case rather than an edge case.
    expect(
      getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), brlCartItems(), { usingSavedCard: true }),
    ).toBeNull();
  });

  it("stays in canonical USD while a non-card payment method is selected", () => {
    // PayPal charges USD or the merchant-account currency at its own rate, never the listed price.
    expect(
      getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), brlCartItems(), { paymentMethod: "paypal" }),
    ).toBeNull();
  });

  it("stays in canonical USD for installment and ordinary subscription carts", () => {
    const brlItem = {
      product: { currency_code: "brl" as const, exchange_rate: 5.45, creator: { id: "seller-a" } },
    };
    expect(
      getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), [{ ...brlItem, pay_in_installments: true }]),
    ).toBeNull();
    expect(
      getCheckoutListedCurrencyDisplay(listedCurrencyPayment(), [{ ...brlItem, recurrence: "monthly" }]),
    ).toBeNull();
  });

  it("renders INR for the server-selected recurring UPI registration lane", () => {
    expect(
      getCheckoutListedCurrencyDisplay(recurringUpiPayment(), [
        {
          product: { currency_code: "inr", exchange_rate: 85.4, creator: { id: "seller-a" } },
          recurrence: "monthly",
        },
      ]),
    ).toEqual({ currencyCode: "inr", rate: 85.4, subunitToUnit: 100 });
  });
});

describe("getCheckoutListedCurrencyAmounts", () => {
  const brl = { currencyCode: "brl" as const, rate: 5.45, subunitToUnit: 100 };

  it("shows listed prices verbatim and converts the USD-side tax and shipping at the stored rate", () => {
    // R$49.90 listed. The surcharge endpoint returns tax and shipping in USD (109 and 545
    // cents), which the charge converts back with this same stored rate — 109 * 5.45 = 594.05
    // and 545 * 5.45 = 2,970.25 — so the visible total equals the intent amount.
    const amounts = getCheckoutListedCurrencyAmounts(brl, {
      lines: [{ priceCents: 4_990, discountCents: 0 }],
      tipCents: 0,
      usdTaxCents: 109,
      usdTaxIncludedCents: 0,
      usdShippingCents: 545,
    });

    if (!amounts) throw new Error("Expected listed-currency amounts");
    expect(amounts.linePriceCents).toEqual([4_990]);
    expect(amounts.taxCents).toBe(594);
    expect(amounts.shippingCents).toBe(2_970);
    expect(amounts.subtotalCents).toBe(4_990);
    expect(amounts.totalCents).toBe(4_990 + 594 + 2_970);
  });

  it("keeps the listed price out of the USD round trip that produced the reported bug", () => {
    // The old rendering divided the listed price by the exchange rate, so a R$49.90 product
    // showed about US$9.15 next to a Stripe sheet charging R$49.90. The listed amount must
    // come through untouched.
    const amounts = getCheckoutListedCurrencyAmounts(brl, {
      lines: [{ priceCents: 4_990, discountCents: 0 }],
      tipCents: 0,
      usdTaxCents: 0,
      usdTaxIncludedCents: 0,
      usdShippingCents: 0,
    });

    if (!amounts) throw new Error("Expected listed-currency amounts");
    expect(amounts.totalCents).toBe(4_990);
    expect(formatPresentmentCents(amounts.totalCents, brl)).toBe("R$49.90");
    expect(Math.floor(4_990 / brl.rate)).toBe(915);
  });

  it("itemizes the discount and adds the tip in the listed currency", () => {
    const amounts = getCheckoutListedCurrencyAmounts(brl, {
      lines: [{ priceCents: 4_990, discountCents: 1_000 }],
      tipCents: 500,
      usdTaxCents: 0,
      usdTaxIncludedCents: 0,
      usdShippingCents: 0,
    });

    if (!amounts) throw new Error("Expected listed-currency amounts");
    expect(amounts.discountCents).toBe(1_000);
    expect(amounts.tipCents).toBe(500);
    expect(amounts.subtotalCents).toBe(5_490);
    expect(amounts.totalCents).toBe(4_490);
  });

  it("displays included tax without adding it to the total", () => {
    // Tax included in the price is already inside the line price, exactly as the canonical
    // USD total treats it — double-counting it would overstate what the buyer pays.
    const amounts = getCheckoutListedCurrencyAmounts(brl, {
      lines: [{ priceCents: 4_990, discountCents: 0 }],
      tipCents: 0,
      usdTaxCents: 0,
      usdTaxIncludedCents: 100,
      usdShippingCents: 0,
    });

    if (!amounts) throw new Error("Expected listed-currency amounts");
    expect(amounts.taxIncludedCents).toBe(545);
    expect(amounts.totalCents).toBe(4_990);
  });

  it("returns nothing when there is no listed-currency lane", () => {
    expect(
      getCheckoutListedCurrencyAmounts(null, {
        lines: [{ priceCents: 4_990, discountCents: 0 }],
        tipCents: 0,
        usdTaxCents: 0,
        usdTaxIncludedCents: 0,
        usdShippingCents: 0,
      }),
    ).toBeNull();
  });
});
