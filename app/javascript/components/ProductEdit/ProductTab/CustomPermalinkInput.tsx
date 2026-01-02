import * as React from "react";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Input } from "$app/components/ui/Input";
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
    <fieldset>
      <legend>
        <label htmlFor={uid}>URL</label>
        <CopyToClipboard text={url}>
          <button type="button" className="font-normal underline">
            Copy URL
          </button>
        </CopyToClipboard>
      </legend>
      <Input>
        <Pill className="-ml-2 shrink-0">{`${currentSeller.subdomain}/l/`}</Pill>
        <input
          id={uid}
          type="text"
          placeholder={uniquePermalink}
          value={value ?? ""}
          onChange={(evt) => onChange(evt.target.value.replace(/\s/gu, "") || null)}
        />
      </Input>
    </fieldset>
  );
};
