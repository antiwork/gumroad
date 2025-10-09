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
      <div className={`has-tooltip ${tooltipPosition}`} aria-describedby={tooltipUid}>
        <div
          className="relative block border border-r-0 py-1 px-2 overflow-hidden whitespace-nowrap text-ellipsis text-[rgb(var(--contrast-accent))]"
          style={{
            paddingRight: "calc(0.5rem + 1em)",
            backgroundImage:
              "linear-gradient(to left, transparent 1em, rgb(var(--accent)) 1em)",
            backgroundRepeat: "no-repeat",
          }}
          itemProp="price"
          content={formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, price)}
        >
          <span
            className="absolute top-0 bottom-0 right-0 border-l"
            style={{
              borderTopWidth: "calc(0.25rem + 0.5lh)",
              borderBottomWidth: "calc(0.25rem + 0.5lh)",
              borderLeftWidth: "var(--border-width)",
              borderRightWidth: "1em",
              borderStyle: "solid",
              borderColor: "rgb(var(--parent-color) / var(--border-alpha))",
              borderRightColor: "transparent",
            }}
          />
          <span
            className="absolute top-0 bottom-0"
            style={{
              right: "var(--border-width)",
              borderTopWidth: "calc(0.25rem + 0.5lh)",
              borderBottomWidth: "calc(0.25rem + 0.5lh)",
              borderRightWidth: "1em",
              borderStyle: "solid",
              borderColor: "rgb(var(--accent))",
              borderRightColor: "transparent",
              borderLeft: "none",
            }}
          />
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
