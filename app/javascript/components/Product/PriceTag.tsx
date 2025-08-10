import * as React from "react";

import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbolAndComma,
} from "$app/utils/currency";
import { formatRecurrenceWithDuration, formatFixedDurationPricing, RecurrenceId } from "$app/utils/recurringPricing";

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
  fixedDurationMonths?: number | null;
  isPayWhatYouWant: boolean;
  isSalesLimited: boolean;
  creatorName?: string | undefined;
  tooltipPosition?: "top" | "right";
};

const getRecurrenceLabel = (
  recurrence: { id: RecurrenceId; duration_in_months: number | null } | undefined,
  fixedDurationMonths: number | null | undefined,
) => {
  if (!recurrence) return null;

  if (fixedDurationMonths) {
    return formatFixedDurationPricing(recurrence.id, fixedDurationMonths);
  }
  return formatRecurrenceWithDuration(recurrence.id, recurrence.duration_in_months);
};

const getRecurrenceSuffix = (recurrence: RecurrenceId) => {
  switch (recurrence) {
    case "monthly":
      return "/month";
    case "yearly":
      return "/year";
    case "quarterly":
      return "/quarter";
    case "biannually":
      return "/6 months";
    case "every_two_years":
      return "/2 years";
    default:
      return "";
  }
};

export const PriceTag = ({
  url,
  currencyCode,
  oldPrice,
  price,
  recurrence,
  fixedDurationMonths,
  isPayWhatYouWant,
  isSalesLimited,
  creatorName,
  tooltipPosition = "right",
}: Props) => {
  const formattedAmount = formatPriceCentsWithCurrencySymbol(currencyCode, price, { symbolFormat: "long" });

  const recurrenceLabel = getRecurrenceLabel(recurrence, fixedDurationMonths);

  // Should match CurrencyHelper#product_card_formatted_price
  const priceTag = (() => {
    if (fixedDurationMonths && recurrence) {
      // For fixed duration: "6-month plan at $10/month"
      const recurrenceSuffix = getRecurrenceSuffix(recurrence.id);

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
    }

    // Regular format: "$10 a month"
    return (
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
  })();
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
