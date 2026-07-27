import * as React from "react";

import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
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
  // The textarea silently stops accepting input at maxLength, which is easy to miss when pasting a
  // long draft in one go: the text just appears cut off mid-sentence with no explanation. Showing the
  // limit up front, plus a running count, makes it clear why and how much room is left.
  const length = (value ?? "").length;
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
      <FieldsetDescription>
        Add a message to the receipt email buyers receive ({length} of {maxLength} characters used).
      </FieldsetDescription>
    </Fieldset>
  );
};
