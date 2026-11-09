import { BuyerLocalCurrencyContext, formatBuyerLocalOrSetPrice } from "$app/utils/currency";

export function formatPrice(
  currencySymbol: string,
  price: number,
  precision: number,
  { noCentsIfWhole }: { noCentsIfWhole: boolean },
): string {
  precision = noCentsIfWhole && price % 1 === 0 ? 0 : precision;
  return (
    currencySymbol +
    price.toLocaleString(undefined, {
      minimumFractionDigits: precision,
      maximumFractionDigits: precision,
    })
  );
}

export function priceCentsToUnit(cents: number, isSingleUnit: boolean): number {
  const unitAmount = cents / (isSingleUnit ? 1 : 100);
  return preciseAmount(unitAmount, isSingleUnit);
}

export function priceUnitToCents(unit: number, isSingleUnit: boolean): number {
  return preciseAmount(unit * (isSingleUnit ? 1 : 100), true);
}

export function preciseAmount(unit: number, isSingleUnit: boolean) {
  return Number(unit.toFixed(isSingleUnit ? 0 : 2));
}

const parseLocaleAwareCurrencyString = (currencyString: string): string | null => {
  if (!currencyString) {
    return null;
  }

  // Remove all non-numericals, period and comma
  let parsedCurrency = currencyString.replace(/[^0-9.,]/gu, "");
  const negativePrefix = /\s*-/u.exec(currencyString) ? "-" : "",
    lastPeriodIndex = parsedCurrency.lastIndexOf("."),
    lastCommaIndex = parsedCurrency.lastIndexOf(","),
    thousandsPeriodIndexInBounds = lastPeriodIndex > 0 && lastPeriodIndex === parsedCurrency.length - 4,
    thousandsCommaIndexInBounds = lastCommaIndex > 0 && lastCommaIndex === parsedCurrency.length - 4;

  // US style formatting is given precedence in matching.

  // Check for US style formatting
  if ((lastPeriodIndex >= parsedCurrency.length - 3 && lastPeriodIndex > 0) || thousandsCommaIndexInBounds) {
    parsedCurrency = parsedCurrency.replace(/,/gu, "");

    const dots = parsedCurrency.match(/\./gu);

    if (dots != null && dots.length === 1) {
      parsedCurrency = parsedCurrency.replace(/,/gu, "");
    } else {
      parsedCurrency = parsedCurrency.replace(/[^0-9]/gu, "");
    }

    return negativePrefix + parsedCurrency;
  }

  // Check for Euro style formatting
  if ((lastCommaIndex >= parsedCurrency.length - 3 && lastCommaIndex > 0) || thousandsPeriodIndexInBounds) {
    parsedCurrency = parsedCurrency.replace(/\./gu, "");

    const commas = parsedCurrency.match(/,/gu);

    if (commas != null && commas.length === 1) {
      parsedCurrency = parsedCurrency.replace(",", ".");
    } else {
      parsedCurrency = parsedCurrency.replace(/[^0-9]/gu, "");
    }

    return negativePrefix + parsedCurrency;
  }

  return lastCommaIndex === -1 && lastPeriodIndex === -1 ? negativePrefix + parsedCurrency : null;
};

export function parsePrice(numberOrString: number | string | null, isSingleUnit: boolean): number | null {
  if (numberOrString == null) return null;
  if (typeof numberOrString === "string") {
    const localeIndependentString = parseLocaleAwareCurrencyString(numberOrString);
    if (localeIndependentString == null) return null;
    numberOrString = parseFloat(localeIndependentString);
  }
  return preciseAmount(numberOrString, isSingleUnit);
}

export function parseUnitStringToPriceCents(amount: string | null, isSingleUnit: boolean) {
  const amountUnit = parsePrice(amount, isSingleUnit);

  if (amountUnit == null) {
    return null;
  }

  return priceUnitToCents(amountUnit, isSingleUnit);
}

export function calculateFirstInstallmentPaymentPriceCents(priceCents: number, numberOfInstallments: number): number {
  return Math.floor(priceCents / numberOfInstallments) + (priceCents % numberOfInstallments);
}

export const formatInstallmentPaymentSchedule = (
  priceCents: number,
  buyerLocalContext: BuyerLocalCurrencyContext,
  numberOfInstallments: number,
) => {
  const baseInstallmentAmount = Math.floor(priceCents / numberOfInstallments);
  const baseInstallmentAmountFormatted = formatBuyerLocalOrSetPrice(baseInstallmentAmount, buyerLocalContext, {
    symbolFormat: "short",
  });

  if (priceCents % numberOfInstallments === 0) {
    return `${numberOfInstallments} equal monthly installments of ${baseInstallmentAmountFormatted}`;
  }

  const firstInstallmentAmount = baseInstallmentAmount + (priceCents % numberOfInstallments);
  const firstInstallmentAmountFormatted = formatBuyerLocalOrSetPrice(firstInstallmentAmount, buyerLocalContext, {
    symbolFormat: "short",
  });

  return `First installment of ${firstInstallmentAmountFormatted}, followed by ${numberOfInstallments - 1} monthly installments of ${baseInstallmentAmountFormatted}`;
};

// Keeps commas: the server's `clean_price` reads "7,900" as grouping and "7,90" as a Euro decimal.
export function sanitizePriceRangeInput(value: string): string {
  const cleaned = value.replace(/[^0-9.,]/gu, "");
  const firstDotIndex = cleaned.indexOf(".");
  if (firstDotIndex === -1) return cleaned;
  return cleaned.slice(0, firstDotIndex + 1) + cleaned.slice(firstDotIndex + 1).replace(/\./gu, "");
}

// Under the new-product Price field and the editor's Amount field: `clean_price` and `PriceInput` both
// read a comma before three digits as thousands and before one or two as cents. Currencies without
// minor units have no cents, so they only get the thousands half.
export const priceCommaHint = (isSingleUnit: boolean): string =>
  isSingleUnit ? "Use a comma for thousands (7,900)." : "Use a comma for thousands (7,900) or for cents (7,90).";
