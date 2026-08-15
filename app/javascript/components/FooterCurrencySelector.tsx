import * as React from "react";

import { readBuyerCurrencyPreference, writeBuyerCurrencyPreference } from "$app/utils/buyerCurrencyPreference";
import { currencyCodeList, findCurrencyByCode, type CurrencyCode } from "$app/utils/currency";

import { Select } from "$app/components/ui/Select";

const currencyCodes: readonly string[] = currencyCodeList;
const isCurrencyCode = (code: string): code is CurrencyCode => currencyCodes.includes(code);

const detectedOptionLabel = (detectedCurrency: string | null | undefined) => {
  const code = detectedCurrency?.toLowerCase();
  if (!code || !isCurrencyCode(code)) return "Detected currency";
  return `${findCurrencyByCode(code).displayFormat} — detected`;
};

// The buyer-facing presentment currency selector that lives in page footers (product pages,
// profile pages, discover). Writes the same cookie the checkout picker reads, then reloads so
// the server re-renders every price through buyer_currency_display_props with the preference.
// An empty value clears the cookie and returns to IP detection. Deliberately shows the raw
// preference, not the per-seller resolved currency — settleability is enforced only at checkout.
// The closed-state empty option still names the IP-detected currency (checkout's
// "$ (US Dollars) — detected" shape) so buyers can see what they are currently being shown.
export const FooterCurrencySelector = ({
  className,
  detectedCurrency,
}: {
  className?: string;
  detectedCurrency?: string | null;
}) => {
  const [value, setValue] = React.useState(() => readBuyerCurrencyPreference() ?? "");

  return (
    <Select
      aria-label="Currency"
      value={value}
      {...(className === undefined ? {} : { wrapperClassName: className })}
      onChange={(e) => {
        const code = e.target.value;
        setValue(code);
        writeBuyerCurrencyPreference(code || null);
        // A ?currency= link outranks the cookie on both client and server, so a plain
        // reload would silently discard this choice. Drop the param and let the cookie carry it.
        const url = new URL(window.location.href);
        url.searchParams.delete("currency");
        window.location.assign(url.toString());
      }}
    >
      <option value="">{detectedOptionLabel(detectedCurrency)}</option>
      {currencyCodeList.map((code) => (
        <option key={code} value={code}>
          {findCurrencyByCode(code).displayFormat}
        </option>
      ))}
    </Select>
  );
};
