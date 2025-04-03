import * as React from "react";

import { CustomButtonTextOption } from "$app/parsers/product";

import { getCtaName } from "$app/components/Product/CtaButton";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

export const CustomButtonTextOptionInput = <T extends CustomButtonTextOption>({
  value,
  onChange,
  options,
}: {
  value: T | null;
  onChange: (value: T) => void;
  options: readonly T[];
}) => {
  const uid = React.useId();

  if (!options[0]) return null;

  return (
    <fieldset>
      <label htmlFor={uid}>Call to action</label>
      <TypeSafeOptionSelect
        id={uid}
        value={value ?? options[0]}
        onChange={onChange}
        options={options.map((option) => ({ id: option, label: getCtaName(option) }))}
      />
    </fieldset>
  );
};
