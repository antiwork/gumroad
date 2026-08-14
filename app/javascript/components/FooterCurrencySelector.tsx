import * as React from "react";

import { readBuyerCurrencyPreference, writeBuyerCurrencyPreference } from "$app/utils/buyerCurrencyPreference";
import { currencyCodeList, findCurrencyByCode } from "$app/utils/currency";

import { Select } from "$app/components/ui/Select";

// The buyer-facing presentment currency selector that lives in page footers (product pages,
// profile pages, discover). Writes the same cookie the checkout picker reads, then reloads so
// the server re-renders every price through buyer_currency_display_props with the preference.
// An empty value clears the cookie and returns to IP detection.
export const FooterCurrencySelector = ({ className }: { className?: string }) => {
  const [value, setValue] = React.useState(() => readBuyerCurrencyPreference() ?? "");

  return (
    <Select
      aria-label="Currency"
      value={value}
      wrapperClassName={className}
      onChange={(e) => {
        const code = e.target.value;
        setValue(code);
        writeBuyerCurrencyPreference(code || null);
        window.location.reload();
      }}
    >
      <option value="">Detected currency</option>
      {currencyCodeList.map((code) => (
        <option key={code} value={code}>
          {findCurrencyByCode(code).displayFormat}
        </option>
      ))}
    </Select>
  );
};
