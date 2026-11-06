import * as React from "react";
import ReactDOMServer from "react-dom/server";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { FollowFormEmbed, FOLLOW_FORM_EMBED_INPUT_ID } from "$app/components/Developer/FollowFormEmbed";
import { DomainSettingsProvider, useDomains } from "$app/components/DomainSettings";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { LinkButton } from "$app/components/ui/LinkButton";
import { Textarea } from "$app/components/ui/Textarea";

export const WaitlistFormEmbed = ({ sellerId, productId }: { sellerId: string; productId: string }) => {
  const domains = useDomains();
  const embedCodeUID = React.useId();
  const descriptionUID = React.useId();
  const [embedHTML, setEmbedHTML] = React.useState("");
  // Rendered after mount: the embed copies its styles from the preview below, which must be in the DOM.
  React.useEffect(
    () =>
      setEmbedHTML(
        ReactDOMServer.renderToString(
          <DomainSettingsProvider value={domains}>
            <FollowFormEmbed sellerId={sellerId} productId={productId} />
          </DomainSettingsProvider>,
        ),
      ),
    [sellerId, productId],
  );

  return (
    <div className="flex flex-col gap-4">
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={FOLLOW_FORM_EMBED_INPUT_ID}>Test your waitlist form with your email</Label>
        </FieldsetTitle>
        <FollowFormEmbed sellerId={sellerId} productId={productId} preview />
      </Fieldset>
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={embedCodeUID}>Waitlist form embed code</Label>
          <CopyToClipboard text={embedHTML} copyTooltip="Copy to Clipboard" tooltipPosition="top">
            <LinkButton className="font-normal">Copy embed code</LinkButton>
          </CopyToClipboard>
        </FieldsetTitle>
        <Textarea id={embedCodeUID} value={embedHTML} aria-describedby={descriptionUID} readOnly />
        <FieldsetDescription id={descriptionUID}>
          People who join the waitlist also subscribe to you.
        </FieldsetDescription>
      </Fieldset>
    </div>
  );
};
