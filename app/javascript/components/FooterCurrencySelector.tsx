import * as React from "react";

import { readBuyerCurrencyPreference, writeBuyerCurrencyPreference } from "$app/utils/buyerCurrencyPreference";
import { classNames } from "$app/utils/classNames";
import { currencyCodeList, findCurrencyByCode, isCurrencyCode } from "$app/utils/currency";

import { Select } from "$app/components/ui/Select";

// The buyer-facing presentment currency selector. Only pages that render a price mount it — see
// PoweredByFooter and HomeFooter, which both default it off. Writes the same cookie the checkout
// picker reads, then reloads so the server re-renders every price with the preference applied.
//
// `shownCurrency` is the currency the page's own product actually rendered in, and only pages with
// one focal product pass it. buyer_currency_display_props falls back to the listed price whenever
// the seller is outside the ramp, the currency is unsettleable, or a rate is missing, so without
// this the selector would name a currency the price above it is not using. Grids of products from
// different sellers pass nothing: each card states its own currency and there is no single claim
// the footer can make about all of them.
export const FooterCurrencySelector = ({
  className,
  detectedCurrency,
  shownCurrency,
}: {
  className?: string | undefined;
  detectedCurrency?: string | null | undefined;
  shownCurrency?: string | null | undefined;
}) => {
  const detected = detectedCurrency?.toLowerCase();
  // Same resolution order as the checkout picker: an explicit pick, then detection, then USD.
  const fallback = detected !== undefined && isCurrencyCode(detected) ? detected : "usd";
  const [value, setValue] = React.useState<string>(() => readBuyerCurrencyPreference() ?? fallback);
  const [navigating, setNavigating] = React.useState(false);

  const shown = shownCurrency?.toLowerCase();
  // Suppressed while navigating: `value` is already the new pick but `shown` still describes the
  // document being replaced, so the mismatch says nothing until the server has answered.
  const unhonoured = !navigating && shown !== undefined && shown !== value;

  return (
    <div className={classNames("flex flex-col items-start gap-1", className)}>
      <Select
        aria-label="Currency"
        value={value}
        disabled={navigating}
        onChange={(e) => {
          const code = e.target.value;
          setValue(code);
          setNavigating(true);
          writeBuyerCurrencyPreference(code);
          // A ?currency= link outranks the cookie on both client and server, so a plain
          // reload would silently discard this choice. Drop the param and let the cookie carry it.
          const url = new URL(window.location.href);
          url.searchParams.delete("currency");
          window.location.assign(url.toString());
        }}
      >
        {currencyCodeList.map((code) => (
          <option key={code} value={code}>
            {findCurrencyByCode(code).displayFormat}
            {code === detected ? " — detected" : ""}
          </option>
        ))}
      </Select>
      {unhonoured ? (
        <div className="text-sm text-muted">
          Not available for this product — showing{" "}
          {isCurrencyCode(shown) ? findCurrencyByCode(shown).displayFormat : shown.toUpperCase()}
        </div>
      ) : null}
    </div>
  );
};
