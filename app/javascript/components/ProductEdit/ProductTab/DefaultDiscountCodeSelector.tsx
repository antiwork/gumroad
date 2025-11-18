import * as React from "react";

import { ComboBox } from "$app/components/ComboBox";
import { ProductEditContext, AvailableDiscountCode } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";

export const DefaultDiscountCodeSelector = () => {
  const context = React.useContext(ProductEditContext);
  if (!context) return null;

  const { product, updateProduct, availableDiscountCodes } = context;
  const defaultOfferCodeId = product.default_offer_code_id;

  const isEnabled = !!defaultOfferCodeId;

  const selectedDiscountCode = availableDiscountCodes?.find((code) => code.id === defaultOfferCodeId) ?? null;

  const [query, setQuery] = React.useState("");

  const formatLabel = (code: AvailableDiscountCode) => {
    const labelBase = code.name || code.code;
    return labelBase;
  };

  React.useEffect(() => {
    if (selectedDiscountCode) {
      setQuery(formatLabel(selectedDiscountCode));
    } else if (!defaultOfferCodeId) {
      setQuery("");
    }
  }, [defaultOfferCodeId, selectedDiscountCode]);

  const allCodes = availableDiscountCodes ?? [];
  const filteredCodes = query
    ? allCodes.filter((code) => formatLabel(code).toLowerCase().includes(query.toLowerCase()))
    : allCodes;

  const handleToggleChange = (enabled: boolean) => {
    if (enabled) {
      const firstDiscountCode = availableDiscountCodes?.[0];
      if (!defaultOfferCodeId && firstDiscountCode) {
        updateProduct({ default_offer_code_id: firstDiscountCode.id });
      }
    } else {
      updateProduct({ default_offer_code_id: null });
      setQuery("");
    }
  };

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={handleToggleChange}
      disabled={allCodes.length === 0}
      label="Automatically apply discount code"
      dropdown={
        <section className="flex flex-col gap-4">
          <fieldset>
            <label htmlFor="default-discount-code">Discount code</label>
            <ComboBox<AvailableDiscountCode>
              editable
              className="w-full"
              input={(props) => (
                <div className="input">
                  <input
                    {...props}
                    id="default-discount-code"
                    type="search"
                    placeholder="Search discount codes"
                    value={query}
                    onChange={(event) => setQuery(event.target.value)}
                    aria-autocomplete="list"
                  />
                </div>
              )}
              options={filteredCodes}
              option={(code, props) => (
                <div
                  {...props}
                  onClick={(event) => {
                    props.onClick?.(event);
                    updateProduct({ default_offer_code_id: code.id });
                    setQuery(formatLabel(code));
                  }}
                  aria-selected={code.id === defaultOfferCodeId}
                >
                  {formatLabel(code)}
                </div>
              )}
            />
          </fieldset>
        </section>
      }
    />
  );
};
