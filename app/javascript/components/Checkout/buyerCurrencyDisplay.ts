import type { SurchargesResponse } from "$app/data/customer_surcharge";
import {
  CurrencyCode,
  formatMinorUnitPriceWithIntl,
  formatPriceCentsWithCurrencySymbol,
  formatUSDCentsWithExpandedCurrencySymbol,
} from "$app/utils/currency";

import type { PaymentMethodType } from "$app/components/Checkout/payment";

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
