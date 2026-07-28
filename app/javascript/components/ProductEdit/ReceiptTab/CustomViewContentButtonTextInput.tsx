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
  const descriptionId = `${uid}-description`;
  // Matches the running count on the Custom message field below, so the two limits in this one form
  // read as a single system rather than two different conventions.
  const charactersUsed = (value ?? "").length;
  return (
    <Fieldset>
      <Label htmlFor={uid}>Button text</Label>
      <Input
        id={uid}
        type="text"
        aria-describedby={descriptionId}
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        maxLength={maxLength}
      />
      <FieldsetDescription id={descriptionId}>
        Customize the download button text on receipts and product pages ({charactersUsed} of {maxLength} characters
        used).
      </FieldsetDescription>
    </Fieldset>
  );
};
