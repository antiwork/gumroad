import * as React from "react";

import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbolAndComma,
} from "$app/utils/currency";
import { formatRecurrenceWithDuration, RecurrenceId } from "$app/utils/recurringPricing";

import { PriceTagForFixedDuration } from "$app/components/Product/PriceTagForFixedDuration";
import { RegularPriceTag } from "$app/components/Product/RegularPriceTag";

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
  fixedDurationPricingLabel?: string | null;
  isPayWhatYouWant: boolean;
  isSalesLimited: boolean;
  creatorName?: string | undefined;
  tooltipPosition?: "top" | "right";
};

const getRecurrenceLabel = (
  recurrence: { id: RecurrenceId; duration_in_months: number | null } | undefined,
  fixedDurationMonths: number | null | undefined,
  fixedDurationPricingLabel: string | null | undefined,
) => {
  if (!recurrence) return null;

  if (fixedDurationMonths) {
    return fixedDurationPricingLabel ?? "";
  }
  return formatRecurrenceWithDuration(recurrence.id, recurrence.duration_in_months);
};

export const PriceTag = ({
  url,
  currencyCode,
  oldPrice,
  price,
  recurrence,
  fixedDurationMonths,
  fixedDurationPricingLabel,
  isPayWhatYouWant,
  isSalesLimited,
  creatorName,
  tooltipPosition = "right",
}: Props) => {
  const formattedAmount = formatPriceCentsWithCurrencySymbol(currencyCode, price, { symbolFormat: "long" });

  const recurrenceLabel = getRecurrenceLabel(recurrence, fixedDurationMonths, fixedDurationPricingLabel);

  // Should match CurrencyHelper#product_card_formatted_price
  const priceTag = (() => {
    if (fixedDurationMonths && recurrence) {
      return (
        <PriceTagForFixedDuration
          currencyCode={currencyCode}
          oldPrice={oldPrice}
          formattedAmount={formattedAmount}
          recurrenceLabel={recurrenceLabel ?? ""}
          isPayWhatYouWant={isPayWhatYouWant}
          recurrenceShortIndicator={null}
        />
      );
    }

    return (
      <RegularPriceTag
        currencyCode={currencyCode}
        oldPrice={oldPrice}
        formattedAmount={formattedAmount}
        isPayWhatYouWant={isPayWhatYouWant}
        recurrenceLabel={recurrenceLabel}
      />
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
