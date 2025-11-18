import * as React from "react";

import { useProductEditContext } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

export const DefaultDiscountCodeSelector = () => {
  const { product, updateProduct, availableDiscountCodes } = useProductEditContext();
  const defaultDiscountCodeId = product.default_discount_code_id;

  const isEnabled = !!defaultDiscountCodeId;

  const selectedDiscountCode = availableDiscountCodes?.find((code) => code.id === defaultDiscountCodeId) ?? null;

  const options =
    availableDiscountCodes?.map((code) => ({
      id: code.id,
      label: `${code.code}${code.name ? ` - ${code.name}` : ""} (${code.discount.type === "cents" ? `$${(code.discount.value / 100).toFixed(2)}` : `${code.discount.value}%`} off)`,
    })) ?? [];

  const handleToggleChange = (enabled: boolean) => {
    if (enabled) {
      const firstDiscountCode = availableDiscountCodes?.[0];
      if (!defaultDiscountCodeId && firstDiscountCode) {
        updateProduct({ default_discount_code_id: firstDiscountCode.id });
      }
    } else {
      updateProduct({ default_discount_code_id: null });
    }
  };

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={handleToggleChange}
      disabled={options.length === 0}
      label="Automatically apply discount code"
      dropdown={
        <section className="flex flex-col gap-4">
          <fieldset>
            <label htmlFor="default-discount-code">Discount code</label>
            <TypeSafeOptionSelect
              id="default-discount-code"
              options={options}
              value={selectedDiscountCode?.id ?? ""}
              onChange={(optionId) => {
                if (optionId) {
                  updateProduct({ default_discount_code_id: optionId });
                } else {
                  updateProduct({ default_discount_code_id: null });
                }
              }}
            />
          </fieldset>
        </section>
      }
    />
  );
};
