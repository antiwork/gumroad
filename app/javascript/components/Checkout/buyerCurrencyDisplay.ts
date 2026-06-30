import type { SurchargesResponse } from "$app/data/customer_surcharge";
import {
  CurrencyCode,
  formatMinorUnitPriceWithIntl,
  formatPriceCentsWithCurrencySymbol,
  formatUSDCentsWithExpandedCurrencySymbol,
} from "$app/utils/currency";

export type CheckoutBuyerCurrencyDisplay = {
  currencyCode: CurrencyCode;
  rate: number;
};

export const getCheckoutBuyerCurrencyDisplay = (
  surcharges: SurchargesResponse | null,
): CheckoutBuyerCurrencyDisplay | null => {
  const quote = surcharges?.buyer_currency_quote;
  return quote ? { currencyCode: quote.currency, rate: quote.rate } : null;
};

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
  );
};
