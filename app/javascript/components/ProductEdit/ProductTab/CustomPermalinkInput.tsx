import * as React from "react";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";

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
      <div className="input">
        <div className="pill">{`${currentSeller.subdomain}/l/`}</div>
        <input
          id={uid}
          type="text"
          placeholder={uniquePermalink}
          value={value ?? ""}
          onChange={(evt) => onChange(evt.target.value.replace(/\s/gu, "") || null)}
        />
      </div>
    </fieldset>
  );
};
