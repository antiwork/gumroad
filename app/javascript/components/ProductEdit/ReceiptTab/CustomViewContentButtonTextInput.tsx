import * as React from "react";

import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

export const CustomViewContentButtonTextInput = ({
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
      <Label htmlFor={uid}>Button text</Label>
      <Input
        id={uid}
        type="text"
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        maxLength={maxLength}
      />
      <FieldsetDescription>
        Customize the download button text on receipts and product pages (max {maxLength} characters).
      </FieldsetDescription>
    </Fieldset>
  );
};
