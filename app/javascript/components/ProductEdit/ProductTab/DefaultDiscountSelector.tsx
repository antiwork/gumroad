import * as React from "react";

import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Select, Option } from "$app/components/Select";
import { ToggleSettingRow } from "$app/components/SettingRow";

export const DefaultDiscountSelector = () => {
  const { product, updateProduct } = useProductEditContext();
  const defaultOfferCode = product.default_offer_code;
  const availableOfferCodes = product.available_offer_codes ?? [];

  const [isEnabled, setIsEnabled] = React.useState(!!defaultOfferCode);
  const [selectedId, setSelectedId] = React.useState<string | null>(defaultOfferCode?.id ?? null);

  React.useEffect(() => {
    if (!isEnabled) {
      updateProduct({ default_offer_code: null });
      return;
    }

    if (!selectedId) {
      return;
    }

    const selected = availableOfferCodes.find((oc) => oc.id === selectedId);
    if (selected) {
      updateProduct({
        default_offer_code: {
          id: selected.id,
          code: selected.label.split(" ")[0] ?? "",
        },
      });
    }
  }, [isEnabled, selectedId, updateProduct, availableOfferCodes]);

  // Don't render if there are no available discount codes
  if (availableOfferCodes.length === 0) {
    return null;
  }

  const options: Option[] = availableOfferCodes.map((oc) => ({
    id: oc.id,
    label: oc.label,
  }));

  const selectedOption = selectedId ? options.find((opt) => opt.id === selectedId) ?? null : null;

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={setIsEnabled}
      label="Apply discount"
      dropdown={
        <fieldset>
          <label htmlFor="default-discount">Discount code</label>
          <Select
            inputId="default-discount"
            options={options}
            value={selectedOption}
            onChange={(opt) => setSelectedId(opt?.id ?? null)}
            placeholder="Begin typing to select a discount code"
            isClearable
          />
        </fieldset>
      }
    />
  );
};
