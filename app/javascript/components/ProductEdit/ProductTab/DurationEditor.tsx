import * as React from "react";

import { NumberInput } from "$app/components/NumberInput";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { WithTooltip } from "$app/components/WithTooltip";

export const DurationEditor = () => {
  const uid = React.useId();
  const { product, updateProduct } = useProductEditContext();
  const [isOpen, setIsOpen] = React.useState(product.duration_in_months != null);

  return (
    <ToggleSettingRow
      value={isOpen}
      onChange={(open) => {
        if (!open) updateProduct({ duration_in_months: null });
        setIsOpen(open);
      }}
      label="Tự động kết thúc tư cách thành viên sau một số tháng"
      dropdown={
        <fieldset>
          <legend>
            <label htmlFor={uid}>Số tháng</label>
          </legend>
          <WithTooltip
            tip="Mọi thay đổi về thời hạn thành viên chỉ áp dụng cho thành viên mới."
            position="bottom"
          >
            <NumberInput
              value={product.duration_in_months}
              onChange={(duration_in_months) => updateProduct({ duration_in_months })}
            >
              {(props) => <input id={uid} placeholder="∞" {...props} />}
            </NumberInput>
          </WithTooltip>
        </fieldset>
      }
    />
  );
};
