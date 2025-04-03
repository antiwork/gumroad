import { formatPrice, parseUnitStringToPriceCents, priceCentsToUnit } from "$app/utils/price";

import currenciesInfo from "../../../config/currencies.json";

const currenciesMap = currenciesInfo.currencies;

// Some terminology:
//
// We call `cents` the lowest possible denomination of a given currency that can be represented in integer numbers.
// For example, $1.23 is 123 cents, EUR 5.67 is 567 (euro)cents, etc. The term "cents" in this context is not tied to a particular currency, like US dollars.
//
// We call `units` the (usually double) representation of a money amount. $1.23 is 1.23 "units"; EUR 5.67 is 5.67 "units"; etc.
//
// (In some currencies, like JPY, units _are_ cents.)

export type CurrencyCode = keyof typeof currenciesMap;
type Currency = {
  code: CurrencyCode;
  isSingleUnit: boolean;
  longSymbol: string;
  shortSymbol: string;
  displayFormat: string;
  minPriceCents: number;
};

export const currencyCodeList: CurrencyCode[] = Object.keys(currenciesMap);

export const findCurrencyByCode = (code: CurrencyCode): Currency => {
  const spec = currenciesMap[code];
  return {
    code,
    isSingleUnit: "single_unit" in spec ? spec.single_unit : false,
    longSymbol: spec.symbol,
    shortSymbol: "short_symbol" in spec ? spec.short_symbol : spec.symbol, // default to long symbol
    displayFormat: spec.display_format,
    minPriceCents: spec.min_price,
  };
};

export const getIsSingleUnitCurrency = (code: CurrencyCode): boolean => {
  const currency = findCurrencyByCode(code);
  return currency.isSingleUnit;
};

export const getLongCurrencySymbol = (code: CurrencyCode): string => {
  const currency = findCurrencyByCode(code);
  return currency.longSymbol;
};

export const getShortCurrencySymbol = (code: CurrencyCode): string => {
  const currency = findCurrencyByCode(code);
  return currency.shortSymbol;
};

// Stripe will not accept payments below certain limits (e.g. $0.50 for USD), this is a way to query these minimum amounts
export const getMinPriceCents = (code: CurrencyCode): number => {
  const currency = findCurrencyByCode(code);
  return currency.minPriceCents;
};

export const parseCurrencyUnitStringToCents = (code: CurrencyCode, unitAmount: string | null): number | null => {
  const currency = findCurrencyByCode(code);
  return parseUnitStringToPriceCents(unitAmount, currency.isSingleUnit);
};

export const formatPriceCentsWithCurrencySymbol = (
  code: CurrencyCode,
  amountCents: number,
  { symbolFormat, noCentsIfWhole }: { symbolFormat: "long" | "short"; noCentsIfWhole?: boolean },
): string => {
  const currency = findCurrencyByCode(code);
  const currencySymbol = symbolFormat === "long" ? currency.longSymbol : currency.shortSymbol;

  return formatPrice(
    currencySymbol,
    priceCentsToUnit(amountCents, currency.isSingleUnit),
    currency.isSingleUnit ? 0 : 2,
    { noCentsIfWhole: noCentsIfWhole !== undefined ? noCentsIfWhole : true },
  );
};

// USD's long symbol is set to $, which is often what we want.
// In some places, though, we want to be more explicit (like cart total), and for these, we want to use US$ as the symbol.
export const formatUSDCentsWithExpandedCurrencySymbol = (amountCents: number): string =>
  formatPrice("US$", priceCentsToUnit(amountCents, false), 2, { noCentsIfWhole: true });

export const formatPriceCentsWithoutCurrencySymbol = (code: CurrencyCode, amountCents: number): string => {
  const currency = findCurrencyByCode(code);
  return formatPrice("", priceCentsToUnit(amountCents, currency.isSingleUnit), currency.isSingleUnit ? 0 : 2, {
    noCentsIfWhole: true,
  });
};

export const formatPriceCentsWithoutCurrencySymbolAndComma = (code: CurrencyCode, amountCents: number): string => {
  const currency = findCurrencyByCode(code);
  const price = priceCentsToUnit(amountCents, currency.isSingleUnit);
  const precision = currency.isSingleUnit || price % 1 === 0 ? 0 : 2;
  return price.toLocaleString("en-US", {
    minimumFractionDigits: precision,
    maximumFractionDigits: precision,
    useGrouping: false,
  });
};
