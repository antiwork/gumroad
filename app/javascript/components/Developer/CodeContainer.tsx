import * as React from "react";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

export const CodeContainer = ({ codeToCopy }: { codeToCopy: string }) => {
  const uid = React.useId();
  const textAreaRef = React.useRef<HTMLTextAreaElement | null>(null);
  React.useEffect(() => {
    if (!textAreaRef.current || textAreaRef.current.scrollHeight <= 0) return;

    textAreaRef.current.style.height = "1px";
    textAreaRef.current.style.height = `${textAreaRef.current.scrollHeight}px`;
  }, [codeToCopy]);

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label htmlFor={uid}>Copy and paste this code into your website</Label>
        <CopyToClipboard tooltipPosition="bottom" text={codeToCopy}>
          <button type="button" className="cursor-pointer font-normal underline all-unset">
            Copy embed code
          </button>
        </CopyToClipboard>
      </FieldsetTitle>
      <Textarea id={uid} ref={textAreaRef} aria-label="Widget code" readOnly value={codeToCopy} />
      <FieldsetDescription>
        We highly recommend you have an SSL certificate to increase buyer confidence.
      </FieldsetDescription>
    </Fieldset>
  );
};
