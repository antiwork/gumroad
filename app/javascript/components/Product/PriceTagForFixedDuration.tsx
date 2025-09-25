import * as React from "react";

import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

export const PriceTagForFixedDuration = ({
  currencyCode,
  oldPrice,
  formattedAmount,
  recurrenceLabel,
  isPayWhatYouWant,
  recurrenceShortIndicator,
}: {
  currencyCode: CurrencyCode;
  oldPrice?: number | undefined;
  formattedAmount: string;
  recurrenceLabel: string;
  isPayWhatYouWant: boolean;
  recurrenceShortIndicator?: string | null;
}) => {
  const recurrenceSuffix = recurrenceShortIndicator ?? "";

  return (
    <>
      {oldPrice != null ? (
        <>
          <s>{formatPriceCentsWithCurrencySymbol(currencyCode, oldPrice, { symbolFormat: "long" })}</s>{" "}
        </>
      ) : null}
      {recurrenceLabel} {formattedAmount}
      {recurrenceSuffix}
      {isPayWhatYouWant ? "+" : null}
    </>
  );
};
