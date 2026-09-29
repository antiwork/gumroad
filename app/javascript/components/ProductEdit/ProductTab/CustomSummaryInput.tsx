import * as React from "react";

import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

export const CustomSummaryInput = ({
  value,
  onChange,
}: {
  value: string | null;
  onChange: (value: string) => void;
}) => {
  const uid = React.useId();
  return (
    <Fieldset>
      <Label htmlFor={uid}>Summary</Label>
      <Input
        id={uid}
        type="text"
        aria-describedby={`${uid}-description`}
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
      />
      <FieldsetDescription id={`${uid}-description`}>
        Shown below the call to action on your product page.
      </FieldsetDescription>
    </Fieldset>
  );
};
