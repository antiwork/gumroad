import * as React from "react";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";

export const CustomPermalinkInput = ({
  value,
  onChange,
  uniquePermalink,
  url,
}: {
  value: string | null;
  onChange: (value: string | null) => void;
  uniquePermalink: string;
  url: string;
}) => {
  const uid = React.useId();
  const currentSeller = useCurrentSeller();

  if (!currentSeller) return null;

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label htmlFor={uid}>URL</Label>
        <CopyToClipboard text={url}>
          <button type="button" className="cursor-pointer font-normal underline all-unset">
            Copy URL
          </button>
        </CopyToClipboard>
      </FieldsetTitle>
      <InputGroup>
        <Pill className="-ml-2 shrink-0">{`${currentSeller.subdomain}/l/`}</Pill>
        <Input
          id={uid}
          type="text"
          placeholder={uniquePermalink}
          value={value ?? ""}
          onChange={(evt) => onChange(evt.target.value.replace(/\s/gu, "") || null)}
        />
      </InputGroup>
    </Fieldset>
  );
};
