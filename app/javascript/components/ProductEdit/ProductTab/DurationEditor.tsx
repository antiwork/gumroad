import * as React from "react";

import { NumberInput } from "$app/components/NumberInput";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
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
      label="Automatically end memberships after a number of months"
      dropdown={
        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor={uid}>Number of months</Label>
          </FieldsetTitle>
          <WithTooltip
            tip="Any change in the length of your membership will only affect new members."
            position="bottom"
          >
            <NumberInput
              value={product.duration_in_months}
              onChange={(duration_in_months) => updateProduct({ duration_in_months })}
            >
              {(props) => <Input id={uid} placeholder="∞" {...props} />}
            </NumberInput>
          </WithTooltip>
        </Fieldset>
      }
    />
  );
};
