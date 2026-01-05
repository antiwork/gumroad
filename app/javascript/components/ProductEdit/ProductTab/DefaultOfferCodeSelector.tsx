import * as React from "react";

import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Details } from "$app/components/Details";
import { Toggle } from "$app/components/Toggle";

import { AvailableOfferCode, useProductEditContext } from "../state";

const formatDiscount = (offerCode: AvailableOfferCode): string => {
  if (offerCode.discount.type === "percent") {
    return `${offerCode.discount.percents}% off`;
  }
  return `${formatPriceCentsWithCurrencySymbol(offerCode.discount.currency as CurrencyCode, offerCode.discount.cents, { symbolFormat: "short" })} off`;
};

export const DefaultOfferCodeSelector = () => {
  const { product, updateProduct, availableOfferCodes } = useProductEditContext();
  const uid = React.useId();

  const activeOfferCodes = availableOfferCodes.filter((code) => code.is_active);
  const hasActiveOfferCodes = activeOfferCodes.length > 0;

  const selectedOfferCode = availableOfferCodes.find((code) => code.id === product.default_offer_code_id);

  const handleToggle = (enabled: boolean) => {
    updateProduct({
      default_offer_code_enabled: enabled,
      default_offer_code_id: enabled && activeOfferCodes.length > 0 ? (activeOfferCodes[0]?.id ?? null) : null,
    });
  };

  const handleCodeChange = (event: React.ChangeEvent<HTMLSelectElement>) => {
    updateProduct({ default_offer_code_id: event.target.value || null });
  };

  if (!hasActiveOfferCodes) {
    return null;
  }

  return (
    <Details
      className="toggle"
      open={product.default_offer_code_enabled}
      summary={
        <Toggle value={product.default_offer_code_enabled} onChange={handleToggle}>
          Auto-apply discount code
        </Toggle>
      }
    >
      <div className="dropdown">
        <fieldset>
          <label htmlFor={`${uid}-offer-code`}>Discount code</label>
          <select
            id={`${uid}-offer-code`}
            value={product.default_offer_code_id ?? ""}
            onChange={handleCodeChange}
          >
            {activeOfferCodes.map((code) => (
              <option key={code.id} value={code.id}>
                {code.code} ({formatDiscount(code)})
                {code.max_purchase_count !== null
                  ? ` - ${code.max_purchase_count - code.times_used} uses left`
                  : ""}
              </option>
            ))}
          </select>
          {selectedOfferCode && (
            <small style={{ marginTop: "var(--spacer-2)", color: "var(--color-text-secondary)" }}>
              This discount will automatically apply to all purchases unless the buyer uses a different code.
            </small>
          )}
        </fieldset>
      </div>
    </Details>
  );
};
