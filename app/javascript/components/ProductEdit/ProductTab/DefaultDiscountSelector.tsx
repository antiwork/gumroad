import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { useProductEditContext, AvailableOfferCode } from "$app/components/ProductEdit/state";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

const formatDiscount = (offerCode: AvailableOfferCode) => {
  if (offerCode.discount.type === "percent") {
    return `${offerCode.discount.value}% off`;
  }
  return `${formatPriceCentsWithCurrencySymbol(offerCode.currency_type, offerCode.discount.value, { symbolFormat: "short" })} off`;
};

export const DefaultDiscountSelector = () => {
  const { product, updateProduct, availableOfferCodes, currencyType } = useProductEditContext();
  const uid = React.useId();

  const hasOfferCodes = availableOfferCodes.length > 0;
  const isEnabled = product.default_offer_code_id !== null;

  const selectedOfferCode = availableOfferCodes.find((code) => code.id === product.default_offer_code_id);

  const handleToggle = (enabled: boolean) => {
    if (enabled && availableOfferCodes.length > 0) {
      // Select the first available offer code
      updateProduct({ default_offer_code_id: availableOfferCodes[0]?.id ?? null });
    } else {
      updateProduct({ default_offer_code_id: null });
    }
  };

  const handleOfferCodeChange = (offerCodeId: string) => {
    updateProduct({ default_offer_code_id: offerCodeId });
  };

  if (!hasOfferCodes) {
    return (
      <fieldset>
        <legend>
          <label>Auto-apply discount</label>
        </legend>
        <p className="text-secondary text-sm">
          No discount codes available.{" "}
          <a href="/checkout/discounts" target="_blank" rel="noreferrer">
            Create a discount code
          </a>{" "}
          to automatically apply it to this product.
        </p>
      </fieldset>
    );
  }

  return (
    <fieldset>
      <legend>
        <label htmlFor={`${uid}-toggle`}>Auto-apply discount</label>
      </legend>
      <div className="flex flex-col gap-4">
        <div className="flex flex-col gap-2">
          <label className="flex items-center gap-2">
            <input
              type="radio"
              name={`${uid}-discount-mode`}
              checked={!isEnabled}
              onChange={() => handleToggle(false)}
            />
            <span>No discount</span>
          </label>
          <label className="flex items-center gap-2">
            <input
              type="radio"
              name={`${uid}-discount-mode`}
              checked={isEnabled}
              onChange={() => handleToggle(true)}
            />
            <span>Apply discount code</span>
          </label>
        </div>

        {isEnabled ? (
          <div className="ml-6">
            <TypeSafeOptionSelect
              id={`${uid}-offer-code`}
              value={product.default_offer_code_id ?? ""}
              onChange={handleOfferCodeChange}
              options={availableOfferCodes.map((offerCode) => ({
                id: offerCode.id,
                label: `${offerCode.code.toUpperCase()}${offerCode.name ? ` - ${offerCode.name}` : ""} (${formatDiscount(offerCode)})`,
              }))}
            />
            {selectedOfferCode ? (
              <p className="text-secondary mt-2 text-sm">
                This discount will be automatically applied when customers view this product.
              </p>
            ) : null}
          </div>
        ) : null}
      </div>
    </fieldset>
  );
};

