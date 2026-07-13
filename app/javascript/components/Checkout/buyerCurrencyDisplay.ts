import type { SurchargesResponse } from "$app/data/customer_surcharge";
import {
  CurrencyCode,
  formatMinorUnitPriceWithIntl,
  formatPriceCentsWithCurrencySymbol,
  formatUSDCentsWithExpandedCurrencySymbol,
} from "$app/utils/currency";

import type { PaymentMethodType } from "$app/components/Checkout/payment";

export type CheckoutBuyerCurrencyDisplay = {
  currencyCode: CurrencyCode;
  rate: number;
  // The backend's authoritative minor-unit scale for the quote currency. Gumroad stores some
  // currencies in non-ISO minor units (e.g. KRW as 1/100 won), so formatting must not rely on
  // the currencies.json single_unit heuristic.
  subunitToUnit: number;
};

export const getCheckoutBuyerCurrencyDisplay = (
  surcharges: SurchargesResponse | null,
  { willSaveCard = false, paymentMethod = "card" }: { willSaveCard?: boolean; paymentMethod?: PaymentMethodType } = {},
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
  return { currencyCode: quote.currency, rate: quote.rate, subunitToUnit: quote.subunit_to_unit };
};

// The quote token must be sent iff buyer-currency totals were displayed: sending it without the
// display (or vice versa) lets the charged amount diverge from what the buyer confirmed.
export const getCheckoutBuyerCurrencyQuoteToken = (
  surcharges: SurchargesResponse | null,
  options: { willSaveCard?: boolean; paymentMethod?: PaymentMethodType } = {},
): string | null =>
  getCheckoutBuyerCurrencyDisplay(surcharges, options) ? (surcharges?.buyer_currency_quote?.token ?? null) : null;

export const toBuyerCurrencyCents = (canonicalCents: number, buyerCurrencyDisplay: CheckoutBuyerCurrencyDisplay) =>
  Math.round(canonicalCents * buyerCurrencyDisplay.rate);

export const toCanonicalCents = (buyerCurrencyCents: number, buyerCurrencyDisplay: CheckoutBuyerCurrencyDisplay) =>
  Math.round(buyerCurrencyCents / buyerCurrencyDisplay.rate);

export const formatCheckoutPrice = (
  price: number,
  buyerCurrencyDisplay?: CheckoutBuyerCurrencyDisplay | null,
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
