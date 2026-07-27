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
  //
  // The count is JS string length, which is what the textarea's own maxLength enforces, so the number
  // shown always matches the limit the seller actually hits while typing. Deliberately NOT aria-live:
  // this updates on every keystroke, and announcing each one would make the field unusable with a
  // screen reader. aria-describedby (as in ProductTab/CustomPermalinkInput) gives non-visual users
  // the limit on focus instead.
  const descriptionId = `${uid}-description`;
  // Named `charactersUsed` rather than `length`: a bare `length` here would shadow the global
  // `window.length`, so deleting this line would still typecheck and silently render 0 forever.
  const charactersUsed = (value ?? "").length;
  return (
    <Fieldset>
      <Label htmlFor={uid}>Custom message</Label>
      <Textarea
        id={uid}
        aria-describedby={descriptionId}
        maxLength={maxLength}
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        rows={3}
      />
      <FieldsetDescription id={descriptionId}>
        Add a message to the receipt email buyers receive ({charactersUsed} of {maxLength} characters used).
      </FieldsetDescription>
    </Fieldset>
  );
};
