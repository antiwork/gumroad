import * as React from "react";

import { useProductEditContext } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

export const ApplyDiscountSelector = () => {
  const { product, updateProduct } = useProductEditContext();
  const availableOfferCodes = product.available_offer_codes;

  const [isEnabled, setIsEnabled] = React.useState(!!product.default_offer_code_id);
  const [selectedCodeId, setSelectedCodeId] = React.useState<string | null>(product.default_offer_code_id ?? null);

  React.useEffect(() => {
    if (!isEnabled) {
      updateProduct({ default_offer_code_id: null });
      return;
    }

    if (selectedCodeId) {
      updateProduct({ default_offer_code_id: selectedCodeId });
    }
  }, [isEnabled, selectedCodeId, updateProduct]);

  if (availableOfferCodes.length === 0) {
    return null;
  }

  const options = availableOfferCodes.map((offerCode) => ({
    id: offerCode.id,
    label: `${offerCode.code} (${offerCode.display_amount} off)`,
  }));

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={(enabled) => {
        setIsEnabled(enabled);
        const firstOption = options[0];
        if (enabled && !selectedCodeId && firstOption) {
          setSelectedCodeId(firstOption.id);
        }
      }}
      label="Apply discount"
      dropdown={
        <fieldset>
          <label htmlFor="default-discount-code">Discount code</label>
          <TypeSafeOptionSelect
            id="default-discount-code"
            value={selectedCodeId ?? ""}
            onChange={setSelectedCodeId}
            options={options}
          />
        </fieldset>
      }
    />
  );
};
