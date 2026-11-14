import * as React from "react";

import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

// BaseVariant#description is a varchar(255): a longer value is cut on save with no error and no
// way to recover the lost text, so the cap has to be visible while the seller types.
export const VARIANT_DESCRIPTION_MAX_LENGTH = 255;

export const VariantDescriptionInput = ({
  id,
  value,
  onChange,
}: {
  id: string;
  value: string;
  onChange: (value: string) => void;
}) => (
  <Fieldset>
    <Label htmlFor={id}>Description</Label>
    <Textarea
      id={id}
      value={value}
      maxLength={VARIANT_DESCRIPTION_MAX_LENGTH}
      aria-describedby={`${id}-length`}
      onChange={(event) => onChange(event.target.value)}
    />
    <FieldsetDescription id={`${id}-length`}>
      {value.length}/{VARIANT_DESCRIPTION_MAX_LENGTH} characters
    </FieldsetDescription>
  </Fieldset>
);
