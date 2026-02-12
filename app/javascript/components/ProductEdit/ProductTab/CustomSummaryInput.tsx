import * as React from "react";

import { Fieldset } from "$app/components/ui/Fieldset";
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
        placeholder="You'll get..."
        value={value ?? ""}
        onChange={(evt) => onChange(evt.target.value)}
      />
    </Fieldset>
  );
};
