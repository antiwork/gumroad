import * as React from "react";

import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbolAndComma,
} from "$app/utils/currency";
import { RecurrenceId, recurrenceLabels } from "$app/utils/recurringPricing";

export const OptionPricePill = ({
  currencyCode,
  originalPriceCents,
  priceCents,
  isPayWhatYouWant,
  recurrence,
  fixedDurationMonths,
  recurrenceShortIndicator,
  fixedDurationPricingLabel,
}: {
  currencyCode: CurrencyCode;
  originalPriceCents: number;
  priceCents: number;
  isPayWhatYouWant: boolean;
  recurrence: RecurrenceId | null;
  fixedDurationMonths: number | null;
  recurrenceShortIndicator?: string | null;
  fixedDurationPricingLabel?: string | null;
}) => (
  <div className="pill">
    {fixedDurationMonths && recurrence ? (
      <>
        {priceCents < originalPriceCents ? (
          <s>{formatPriceCentsWithCurrencySymbol(currencyCode, originalPriceCents, { symbolFormat: "long" })}</s>
        ) : null}{" "}
        {fixedDurationPricingLabel}{" "}
        {formatPriceCentsWithCurrencySymbol(currencyCode, priceCents, { symbolFormat: "long" })}
        {recurrenceShortIndicator ?? ""}
        {isPayWhatYouWant ? "+" : null}
      </>
    ) : (
      <>
        {priceCents < originalPriceCents ? (
          <s>{formatPriceCentsWithCurrencySymbol(currencyCode, originalPriceCents, { symbolFormat: "long" })}</s>
        ) : null}{" "}
        {formatPriceCentsWithCurrencySymbol(currencyCode, priceCents, { symbolFormat: "long" })}
        {isPayWhatYouWant ? "+" : null}
        {recurrence ? ` ${recurrenceLabels[recurrence]}` : null}
      </>
    )}
    <div itemProp="price" hidden>
      {formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, priceCents)}
    </div>
    <div itemProp="priceCurrency" hidden>
      {currencyCode}
    </div>
  </div>
);
