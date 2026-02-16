import * as React from "react";

import { classNames } from "$app/utils/classNames";
import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbolAndComma,
} from "$app/utils/currency";
import { formatRecurrenceWithDuration, RecurrenceId } from "$app/utils/recurringPricing";

import { WithTooltip } from "$app/components/WithTooltip";

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
  const borderClasses = "border-r-transparent border-[calc(0.5lh+--spacing(1))] border-l-1";

  return (
    <div itemScope itemProp="offers" itemType="https://schema.org/Offer" className="flex items-center">
      <WithTooltip position={tooltipPosition} tip={priceTag}>
        <div className="relative grid grid-flow-col border border-r-0 border-border">
          <div
            className="bg-accent px-2 py-1 text-accent-foreground"
            itemProp="price"
            content={formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, price)}
          >
            {priceTag}
          </div>
          <div className={classNames("border-border", borderClasses)} />
          <div className={classNames("absolute top-0 right-px bottom-0 border-accent", borderClasses)} />
        </div>
      </WithTooltip>
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
