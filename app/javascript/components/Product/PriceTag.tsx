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
    <div
      itemScope
      itemProp="offers"
      itemType="https://schema.org/Offer"
      style={{ display: "flex", alignItems: "center" }}
    >
      <div className={`has-tooltip ${tooltipPosition}`} aria-describedby={tooltipUid}>
        <div
          className="price"
          itemProp="price"
          content={formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, price)}
        >
          {priceTag}
        </div>
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
