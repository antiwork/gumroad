import * as React from "react";

import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbolAndComma,
} from "$app/utils/currency";
import { formatRecurrenceWithDuration, RecurrenceId } from "$app/utils/recurringPricing";

type Props = {
  url?: string;
  currencyCode: CurrencyCode;
  price: number;
  oldPrice?: number | undefined;
  recurrence?:
    | {
        id: RecurrenceId;
        duration_in_months: number | null;
      }
    | undefined;
  isPayWhatYouWant: boolean;
  isSalesLimited: boolean;
  creatorName?: string | undefined;
  tooltipPosition?: "top" | "right";
};

export const PriceTag = ({
  url,
  currencyCode,
  oldPrice,
  price,
  recurrence,
  isPayWhatYouWant,
  isSalesLimited,
  creatorName,
  tooltipPosition = "right",
}: Props) => {
  const formattedAmount = formatPriceCentsWithCurrencySymbol(currencyCode, price, { symbolFormat: "long" });

  const recurrenceLabel = recurrence
    ? formatRecurrenceWithDuration(recurrence.id, recurrence.duration_in_months)
    : null;

  // Should match CurrencyHelper#product_card_formatted_price
  const priceTag = (
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
  const tooltipUid = React.useId();

  return (
    <div itemScope itemProp="offers" itemType="https://schema.org/Offer" className="flex items-center">
      <div
        className={`has-tooltip ${tooltipPosition} grid-flow-col border border-r-0 border-border`}
        aria-describedby={tooltipUid}
      >
        <div
          // Round up line height to prevent subpixel rendering issues - https://issues.chromium.org/issues/360846285
          className="box-content h-[round(up,1lh,1px)] bg-accent px-2 py-1 text-black"
          itemProp="price"
          content={formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, price)}
        >
          {priceTag}
        </div>
        <svg viewBox="0 0 1 2" className="h-full">
          <polygon className="fill-accent" points="0,0 1,0 0,1 1,2 0,2" />
          <polyline points="1,0 0,1 1,2" fill="none" className="stroke-black" vectorEffect="non-scaling-stroke" />
        </svg>
        <div role="tooltip" id={tooltipUid}>
          {priceTag}
        </div>
      </div>
      <link itemProp="url" href={url} />
      <div itemProp="availability" hidden>
        {`https://schema.org/${isSalesLimited ? "LimitedAvailability" : "InStock"}`}
      </div>
      <div itemProp="priceCurrency" hidden>
        {currencyCode}
      </div>
      {creatorName ? (
        <div itemProp="seller" itemType="https://schema.org/Person" hidden>
          <div itemProp="name" hidden>
            {creatorName}
          </div>
        </div>
      ) : null}
    </div>
  );
};
