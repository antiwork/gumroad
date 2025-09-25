import * as React from "react";

import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

export const RegularPriceTag = ({
  currencyCode,
  oldPrice,
  formattedAmount,
  isPayWhatYouWant,
  recurrenceLabel,
}: {
  currencyCode: CurrencyCode;
  oldPrice?: number | undefined;
  formattedAmount: string;
  isPayWhatYouWant: boolean;
  recurrenceLabel: string | null;
}) => (
  <>
    {oldPrice != null ? (
      <>
        <s>{formatPriceCentsWithCurrencySymbol(currencyCode, oldPrice, { symbolFormat: "long" })}</s>{" "}
      </>
    ) : null}
    {formattedAmount}
    {isPayWhatYouWant ? "+" : null}
    {recurrenceLabel ? ` ${recurrenceLabel}` : null}
  </>
);
