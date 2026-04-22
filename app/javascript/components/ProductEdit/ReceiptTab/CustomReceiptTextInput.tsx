import * as React from "react";

import { Fieldset } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

export const CustomReceiptTextInput = ({
  value,
  onChange,
  maxLength,
}: {
  value: string | null;
  onChange: (value: string) => void;
  maxLength: number;
}) => {
  const uid = React.useId();
  return (
    <Fieldset>
      <Label htmlFor={uid}>Custom message</Label>
      <Textarea
        id={uid}
        maxLength={maxLength}
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        rows={3}
      />
    </Fieldset>
  );
};
