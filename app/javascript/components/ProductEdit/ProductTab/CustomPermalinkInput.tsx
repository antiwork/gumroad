import * as React from "react";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { LinkButton } from "$app/components/ui/LinkButton";
import { Pill } from "$app/components/ui/Pill";

// Must match the server's format validation on Link#custom_permalink
// (/\A[a-zA-Z0-9_-]+\z/) and its length limit (Link::CUSTOM_PERMALINK_MAX_LENGTH).
// The input previously only stripped whitespace, so a seller could type any
// other punctuation and only learn it wasn't allowed after saving — and the
// rejection didn't say which characters were the problem.
const DISALLOWED_CHARACTERS = /[^a-zA-Z0-9_-]/gu;
const MAX_LENGTH = 255;

// Remove the disallowed characters first, then cap the length. Doing it in that
// order matters: the browser's own `maxLength` attribute would cut the raw text
// off at 255 characters *before* this code runs, so pasting a longer string that
// mixes in disallowed characters (spaces, punctuation) would throw away valid
// characters from the end even though the cleaned-up value fits well within the
// limit. Because the cap is applied here, the input deliberately has no
// maxLength attribute.
const sanitizePermalink = (rawValue: string) => rawValue.replace(DISALLOWED_CHARACTERS, "").slice(0, MAX_LENGTH);

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
          <LinkButton className="font-normal">Copy URL</LinkButton>
        </CopyToClipboard>
      </FieldsetTitle>
      <InputGroup>
        <Pill className="-ml-2 shrink-0">{`${currentSeller.subdomain}/l/`}</Pill>
        <Input
          id={uid}
          type="text"
          aria-describedby={`${uid}-description`}
          placeholder={uniquePermalink}
          value={value ?? ""}
          onChange={(evt) => onChange(sanitizePermalink(evt.target.value) || null)}
        />
      </InputGroup>
      <FieldsetDescription id={`${uid}-description`}>
        Letters, numbers, dashes, and underscores only. Each of your products needs its own — if this one is already
        taken, try adding a word or a number.
      </FieldsetDescription>
    </Fieldset>
  );
};
