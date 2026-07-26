import type { SurchargesResponse } from "$app/data/customer_surcharge";
import {
  CurrencyCode,
  formatMinorUnitPriceWithIntl,
  formatPriceCentsWithCurrencySymbol,
  formatUSDCentsWithExpandedCurrencySymbol,
} from "$app/utils/currency";

import type { CartItem } from "$app/components/Checkout/cartState";
import type { CheckoutPaymentConfig, PaymentMethodType } from "$app/components/Checkout/payment";

type BuyerCurrencyQuote = NonNullable<SurchargesResponse["buyer_currency_quote"]>;
export type BuyerCurrencyLineAllocation = NonNullable<BuyerCurrencyQuote["line_allocations"]>[number];

type CheckoutBuyerCurrencyOptions = {
  cartPermalinks: readonly string[];
  willSaveCard?: boolean;
  paymentMethod?: PaymentMethodType;
};

export type CheckoutBuyerCurrencyDisplay = {
  currencyCode: CurrencyCode;
  rate: number;
  // The backend's authoritative minor-unit scale for the quote currency. Gumroad stores some
  // currencies in non-ISO minor units (e.g. KRW as 1/100 won), so formatting must not rely on
  // the currencies.json single_unit heuristic.
  subunitToUnit: number;
  // The locked buyer-currency total and the server's split of it across the cart lines (in
  // cart order). The checkout table renders these amounts verbatim instead of converting
  // each row itself: independent per-row rounding can visibly disagree with the locked
  // total by a cent, and with the amounts the charge later persists for the receipt.
  presentmentTotalCents: number;
  lineAllocations: BuyerCurrencyLineAllocation[];
};

// Everything the checkout table needs to render a non-USD amount: which currency to label it
// with, how many minor units make one unit of it, and the rate that turns a canonical USD cent
// figure into that currency. Both non-USD checkout lanes produce one of these — the FX-quoted
// buyer-currency lane (rate from the locked quote) and the method-forced listed-currency lane
// (rate from the product's stored USD exchange rate) — so every formatting helper below works
// the same way for either, and the rest of the checkout never has to know which lane it is on.
export type CheckoutLocalCurrencyFormat = Pick<CheckoutBuyerCurrencyDisplay, "currencyCode" | "rate" | "subunitToUnit">;

// The subset of the FX lane's options the listed lane needs: which payment the buyer has selected,
// since only a new card confirmed through the Payment Element charges in the listed currency.
//
// Unlike the FX-quoted lane, `willSaveCard` is deliberately NOT consulted here. On the FX lane,
// saving a card reroutes the charge to the canonical path, so the display must follow. On this
// client-confirm lane the checkbox changes nothing about the charge: the submit branch runs on
// "client-confirm and not a saved card" alone, the ConfirmationToken inherits the element's
// mounted (listed) currency, and the client-confirm payload never carries `save_card`
// (see buildStartCartPurchasePayload in $app/data/purchase.ts). Gating on it would re-show the
// wrong USD summary for every logged-in buyer entering a new card, since the checkbox defaults
// to checked while logged in.
export type CheckoutListedCurrencyOptions = Pick<CheckoutBuyerCurrencyOptions, "paymentMethod"> & {
  usingSavedCard?: boolean;
};

export const getCheckoutBuyerCurrencyDisplay = (
  surcharges: SurchargesResponse | null,
  { cartPermalinks, willSaveCard = false, paymentMethod = "card" }: CheckoutBuyerCurrencyOptions,
): CheckoutBuyerCurrencyDisplay | null => {
  const quote = surcharges?.buyer_currency_quote;
  // Saving a card charges through the canonical path (buyer-presentment excludes
  // setup_future_charges in PR 1), so buyer-currency totals must not be displayed —
  // the buyer would be charged canonical USD, not the locked local-currency amount.
  // The same applies to non-card payment methods: PayPal (and the wallet sheet, which
  // is withheld on presentment carts anyway) can only charge canonical USD, and the
  // charge path fails closed if a quote token arrives on a charge that cannot present —
  // so while such a method is selected the cart must show the USD totals it will charge.
  if (!quote || willSaveCard || paymentMethod !== "card") return null;

  const lineAllocations = quote.line_allocations;
  if (!Array.isArray(lineAllocations)) return null;
  if (lineAllocations.length !== cartPermalinks.length) return null;
  if (!lineAllocations.every((allocation, index) => allocation.permalink === cartPermalinks[index])) return null;
  if (
    lineAllocations.some(
      (allocation) =>
        allocation.price_cents + allocation.tip_cents + allocation.tax_cents + allocation.shipping_cents !==
        allocation.total_cents,
    )
  )
    return null;
  if (lineAllocations.reduce((sum, allocation) => sum + allocation.total_cents, 0) !== quote.presentment_total_cents)
    return null;

  return {
    currencyCode: quote.currency,
    rate: quote.rate,
    subunitToUnit: quote.subunit_to_unit,
    presentmentTotalCents: quote.presentment_total_cents,
    lineAllocations,
  };
};

// The quote token must be sent iff buyer-currency totals were displayed: sending it without the
// display (or vice versa) lets the charged amount diverge from what the buyer confirmed.
export const getCheckoutBuyerCurrencyQuoteToken = (
  surcharges: SurchargesResponse | null,
  options: CheckoutBuyerCurrencyOptions,
): string | null =>
  getCheckoutBuyerCurrencyDisplay(surcharges, options) ? (surcharges?.buyer_currency_quote?.token ?? null) : null;

// The method-forced local-method lane (a single product priced in the currency the payment method
// forces — a BRL product paid with Pix, an EUR product with iDEAL, an INR product with UPI).
// Charge::MethodForcedPresentment charges that listed price directly and there is no FX quote
// anywhere in the flow, so the cart must be shown in the listed currency: converting the listed
// price to USD for display (what happens when this returns null) showed a Brazilian buyer a
// US$9.16 total next to a Stripe sheet about to charge R$49.90 (gumroad-private#1371).
//
// `rate` is the product's own stored USD exchange rate — the same rate the charge uses to convert
// the USD-side amounts (tax, shipping) back into the listed currency — so the displayed rows and
// the charged amounts agree by construction rather than by coincidence.
//
// Returns null (canonical USD display, today's behavior) unless the server chose this lane AND the
// payment the buyer has actually selected will go through it AND the cart still has the
// single-item, priced-in-that-currency shape the lane assumes.
//
// The payment-selection gates matter as much as the cart shape, and for the same reason as on the
// FX-quoted lane above: only a new card confirmed through the Payment Element reaches
// Charge::MethodForcedPresentment. A saved card (the default whenever the buyer has one on file)
// and PayPal both charge canonical USD through other paths, so showing listed-currency totals for
// them would recreate exactly the display/charge mismatch this lane exists to fix — just pointed
// at a different set of buyers.
export const getCheckoutListedCurrencyDisplay = (
  checkoutPayment: CheckoutPaymentConfig,
  // Only the pricing/plan fields are read, so callers can pass cart items directly and tests
  // don't have to build a whole product.
  cartItems: readonly {
    product: Pick<CartItem["product"], "currency_code" | "exchange_rate">;
    pay_in_installments?: boolean;
    recurrence?: string | null;
  }[],
  { paymentMethod = "card", usingSavedCard = false }: CheckoutListedCurrencyOptions = {},
): CheckoutLocalCurrencyFormat | null => {
  if (checkoutPayment.integration !== "payment_element_client_confirm") return null;
  const listedCurrency = checkoutPayment.elements_options.listed_currency_display;
  if (!listedCurrency) return null;
  if (usingSavedCard || paymentMethod !== "card") return null;
  if (cartItems.length !== 1) return null;

  const item = cartItems[0];
  const product = item?.product;
  if (!product) return null;
  // Installment plans and subscriptions are shapes the client-confirm Element never accepts, so
  // the server withholds this lane for them at render. Both are toggleable in the cart's Edit
  // popover afterwards, and `checkoutPayment` is an Inertia prop that does not refresh on cart
  // edits — so without re-checking here, toggling "pay in installments" would leave listed-currency
  // rows on screen for a charge that has silently dropped back to canonical USD.
  if (item.pay_in_installments) return null;
  if (item.recurrence) return null;
  if (product.currency_code !== listedCurrency.currency) return null;
  // A zero or missing rate would make every converted row 0; fall back to canonical USD instead.
  if (!(product.exchange_rate > 0)) return null;
  if (!(listedCurrency.subunit_to_unit > 0)) return null;

  return {
    currencyCode: product.currency_code,
    rate: product.exchange_rate,
    subunitToUnit: listedCurrency.subunit_to_unit,
  };
};

export const toBuyerCurrencyCents = (
  canonicalCents: number,
  buyerCurrencyDisplay: Pick<CheckoutBuyerCurrencyDisplay, "rate">,
) => Math.round(canonicalCents * buyerCurrencyDisplay.rate);

export const toCanonicalCents = (
  buyerCurrencyCents: number,
  buyerCurrencyDisplay: Pick<CheckoutBuyerCurrencyDisplay, "rate">,
) => Math.round(buyerCurrencyCents / buyerCurrencyDisplay.rate);

// All the buyer-currency amounts the checkout table displays, derived from the server's
// per-line allocation of the locked total so that (line items − discount + tip + tax +
// shipping) sums exactly to the locked total — and each line matches the amount the charge
// later persists for the receipt. Returns null when the allocation doesn't line up with the
// cart lines; the quote usability gate normally catches that first and keeps the checkout in
// canonical currency until a matching response arrives.
export type CheckoutPresentmentAmounts = {
  // Per cart line, in cart order: the allocated (charged) amount plus the line's converted
  // discount, since the table shows pre-discount line prices with the discount itemized in
  // its own row.
  linePriceCents: number[];
  discountCents: number;
  tipCents: number;
  taxCents: number;
  shippingCents: number;
  subtotalCents: number;
  totalCents: number;
};

export const getCheckoutPresentmentAmounts = (
  buyerCurrencyDisplay: CheckoutBuyerCurrencyDisplay | null | undefined,
  cartLines: { permalink: string; discountCents: number }[],
): CheckoutPresentmentAmounts | null => {
  if (!buyerCurrencyDisplay) return null;
  const allocations = buyerCurrencyDisplay.lineAllocations;
  if (allocations.length !== cartLines.length) return null;
  if (!allocations.every((allocation, index) => allocation.permalink === cartLines[index]?.permalink)) return null;

  const lineDiscountCents = cartLines.map((line) =>
    toBuyerCurrencyCents(Math.max(line.discountCents, 0), buyerCurrencyDisplay),
  );
  const linePriceCents = allocations.map(
    (allocation, index) => allocation.price_cents + (lineDiscountCents[index] ?? 0),
  );
  const discountCents = lineDiscountCents.reduce((sum, cents) => sum + cents, 0);
  const tipCents = allocations.reduce((sum, allocation) => sum + allocation.tip_cents, 0);
  const taxCents = allocations.reduce((sum, allocation) => sum + allocation.tax_cents, 0);
  const shippingCents = allocations.reduce((sum, allocation) => sum + allocation.shipping_cents, 0);

  return {
    linePriceCents,
    discountCents,
    tipCents,
    taxCents,
    shippingCents,
    subtotalCents: linePriceCents.reduce((sum, cents) => sum + cents, 0) + tipCents,
    totalCents: buyerCurrencyDisplay.presentmentTotalCents,
  };
};

export const formatPresentmentCents = (
  cents: number,
  buyerCurrencyDisplay: Pick<CheckoutBuyerCurrencyDisplay, "currencyCode" | "subunitToUnit">,
) => formatMinorUnitPriceWithIntl(buyerCurrencyDisplay.currencyCode, cents, buyerCurrencyDisplay.subunitToUnit);

// All the listed-currency amounts the checkout table displays on the method-forced lane. Two
// different kinds of input meet here, and keeping them straight is the whole point of this
// function:
//
//   * Line prices, discounts and the tip are ALREADY in the listed currency — they come from the
//     cart, which stores the seller's set prices in their own minor units, and the charge bills
//     that listed amount as-is. They must be displayed verbatim: converting them to USD and back
//     would round twice and could disagree with the charge by a cent.
//   * Tax and shipping come back from the surcharge endpoint in USD, so they are converted with
//     the product's stored exchange rate — the same rate
//     Charge::MethodForcedPresentment#direct_listed_amount_result uses on those same two figures,
//     so the totals shown here and the amount charged agree by construction.
//
// Returns null when there is no listed-currency lane, leaving every row in canonical USD.
export type CheckoutListedCurrencyAmounts = {
  // Per cart line, in cart order: the line's undiscounted price, since the table itemizes the
  // discount in its own row.
  linePriceCents: number[];
  discountCents: number;
  tipCents: number;
  taxCents: number;
  taxIncludedCents: number;
  shippingCents: number;
  subtotalCents: number;
  totalCents: number;
};

export const getCheckoutListedCurrencyAmounts = (
  listedCurrency: CheckoutLocalCurrencyFormat | null | undefined,
  {
    lines,
    tipCents,
    usdTaxCents,
    usdTaxIncludedCents,
    usdShippingCents,
  }: {
    // The line prices/discounts are already in the listed currency's minor units (that is what the
    // cart holds on this lane); `tipCents` must be converted by the caller, since the tip is
    // canonical USD cents in checkout state.
    lines: { priceCents: number; discountCents: number }[];
    tipCents: number;
    usdTaxCents: number;
    usdTaxIncludedCents: number;
    usdShippingCents: number;
  },
): CheckoutListedCurrencyAmounts | null => {
  if (!listedCurrency) return null;

  const linePriceCents = lines.map((line) => line.priceCents);
  const discountCents = lines.reduce((sum, line) => sum + Math.max(line.discountCents, 0), 0);
  const taxCents = toBuyerCurrencyCents(usdTaxCents, listedCurrency);
  const taxIncludedCents = toBuyerCurrencyCents(usdTaxIncludedCents, listedCurrency);
  const shippingCents = toBuyerCurrencyCents(usdShippingCents, listedCurrency);
  const subtotalCents = linePriceCents.reduce((sum, cents) => sum + cents, 0) + tipCents;

  return {
    linePriceCents,
    discountCents,
    tipCents,
    taxCents,
    taxIncludedCents,
    shippingCents,
    subtotalCents,
    // Tax included in the price is already part of the line prices, so it is only ever displayed,
    // never added — exactly as the canonical USD total treats it.
    totalCents: subtotalCents - discountCents + taxCents + shippingCents,
  };
};

export const formatCheckoutPrice = (
  price: number,
  buyerCurrencyDisplay?: Pick<CheckoutBuyerCurrencyDisplay, "currencyCode" | "rate" | "subunitToUnit"> | null,
  {
    usdSymbolFormat = "expanded",
    noCentsIfWhole = true,
  }: { usdSymbolFormat?: "expanded" | "short"; noCentsIfWhole?: boolean } = {},
) => {
  const canonicalCents = Math.floor(price);
  if (!buyerCurrencyDisplay) {
    return usdSymbolFormat === "expanded"
      ? formatUSDCentsWithExpandedCurrencySymbol(canonicalCents)
      : formatPriceCentsWithCurrencySymbol("usd", canonicalCents, {
          symbolFormat: "short",
          noCentsIfWhole,
        });
  }

  return formatMinorUnitPriceWithIntl(
    buyerCurrencyDisplay.currencyCode,
    toBuyerCurrencyCents(canonicalCents, buyerCurrencyDisplay),
    buyerCurrencyDisplay.subunitToUnit,
  );
};
