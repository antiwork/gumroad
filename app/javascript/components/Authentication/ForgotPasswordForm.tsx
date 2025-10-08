import * as React from "react";

import { renewPassword } from "$app/data/login";
import { assertResponseError } from "$app/utils/request";

import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { Separator } from "$app/components/Separator";
import { showAlert } from "$app/components/server-components/Alert";

type SaveState = { type: "initial" | "submitting" } | { type: "error"; message: string };

export const ForgotPasswordForm = ({ onClose }: { onClose: () => void }) => {
  const uid = React.useId();
  const [email, setEmail] = React.useState("");
  const [saveState, setSaveState] = React.useState<SaveState>({ type: "initial" });

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setSaveState({ type: "submitting" });
    try {
      await renewPassword(email);
      showAlert("Password reset sent! Please make sure to check your spam folder.", "success");
      setSaveState({ type: "initial" });
    } catch (e) {
      assertResponseError(e);
      setSaveState({ type: "error", message: e.message });
    }
  };

  return (
    <form onSubmit={(e) => void handleSubmit(e)}>
      <SocialAuth />
      <Separator>
        <span>or</span>
      </Separator>
      <section>
        {saveState.type === "error" ? (
          <div role="alert" className="danger">
            {saveState.message}
          </div>
        ) : null}
        <fieldset>
          <legend>
            <label htmlFor={uid}>Email to send reset instructions to</label>
          </legend>
          <input id={uid} type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </fieldset>
        <Button color="primary" type="submit" disabled={saveState.type === "submitting"}>
          {saveState.type === "submitting" ? "Sending..." : "Send"}
        </Button>
        <Button onClick={onClose}>Cancel</Button>
      </section>
    </form>
  );
};
