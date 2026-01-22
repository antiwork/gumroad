import * as React from "react";

import { followFromEmbed } from "$app/data/follow_embed";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { getAppliedStyles } from "$app/utils/styles";

import { Button } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { showAlert } from "$app/components/server-components/Alert";

export const FOLLOW_FORM_EMBED_INPUT_ID = "gumroad-follow-form-embed-input";

export const FollowFormEmbed = ({ sellerId, preview }: { sellerId: string; preview?: boolean }) => {
  const [email, setEmail] = React.useState("");
  const appDomain = useAppDomain();
  const followFormRef = React.useRef<HTMLDivElement & HTMLFormElement>(null);

  const styles = React.useMemo(() => {
    if (preview) return;
    const button = document.getElementById("gumroad-follow-form-embed-button");
    const input = document.getElementById(FOLLOW_FORM_EMBED_INPUT_ID);
    const form = document.getElementById("gumroad-follow-form-embed");
    if (!button || !input || !form) return;
    return (
      [...getAppliedStyles(form)]
        .map(([modifier, styles]) => `#gumroad-follow-form-embed${modifier}{${styles}}`)
        .join("") +
      [...getAppliedStyles(button)]
        .map(([modifier, styles]) => `#gumroad-follow-form-embed-button${modifier}{${styles}}`)
        .join("") +
      [...getAppliedStyles(input)]
        .map(([modifier, styles]) => `#gumroad-follow-form-embed-input${modifier}{${styles}}`)
        .join("")
    );
  }, []);

  const FollowForm = preview ? "div" : "form";
  return (
    <>
      {styles ? <style dangerouslySetInnerHTML={{ __html: styles }} /> : null}
      <FollowForm
        className="flex gap-2"
        ref={followFormRef}
        action={Routes.follow_user_from_embed_form_url({ host: appDomain })}
        method="post"
        id="gumroad-follow-form-embed"
      >
        <input type="hidden" name="seller_id" value={sellerId} />
        <input
          id={FOLLOW_FORM_EMBED_INPUT_ID}
          type="email"
          placeholder="Your email address"
          name="email"
          className="flex-1"
          value={email}
          onChange={(evt) => setEmail(evt.target.value)}
        />
        <Button
          id="gumroad-follow-form-embed-button"
          color="primary"
          type="submit"
          onClick={asyncVoid(async (evt) => {
            if (!preview) return;
            evt.preventDefault();
            try {
              await followFromEmbed(sellerId, email);
              showAlert("Check your inbox to confirm your follow request.", "success");
            } catch (e) {
              assertResponseError(e);
              showAlert("Sorry, something went wrong. Please try again.", "error");
            }
          })}
        >
          Follow
        </Button>
      </FollowForm>
    </>
  );
};
