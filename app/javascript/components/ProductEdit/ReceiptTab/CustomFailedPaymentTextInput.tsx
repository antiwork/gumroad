import * as React from "react";

import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

export const CustomFailedPaymentTextInput = ({
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
  const charactersUsed = (value ?? "").length;
  return (
    <Fieldset>
      <Label htmlFor={uid}>Failed payment message</Label>
      <Textarea
        id={uid}
        aria-describedby={descriptionId}
        maxLength={maxLength}
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
        rows={3}
      />
      <FieldsetDescription id={descriptionId}>
        Shown in the email buyers get when a recurring payment fails. Plain text only, no links: we add the link to
        update their payment method ({charactersUsed} of {maxLength} characters used).
      </FieldsetDescription>
    </Fieldset>
  );
};
