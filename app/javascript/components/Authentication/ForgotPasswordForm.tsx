import * as React from "react";

import { renewPassword } from "$app/data/login";
import { assertResponseError } from "$app/utils/request";

import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { Input } from "$app/components/Input";
import { Separator } from "$app/components/Separator";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";

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
    <form onSubmit={(e) => void handleSubmit(e)} className="flex flex-col gap-12">
      <SocialAuth />
      <Separator>
        <span>or</span>
      </Separator>
      <section className="flex flex-col gap-8 pb-12">
        {saveState.type === "error" ? <Alert variant="danger">{saveState.message}</Alert> : null}
        <fieldset className="flex flex-col space-y-2">
          <legend>
            <label className="cursor-pointer" htmlFor={uid}>
              Email to send reset instructions to
            </label>
          </legend>
          <Input id={uid} type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </fieldset>
        <Button color="primary" type="submit" disabled={saveState.type === "submitting"}>
          {saveState.type === "submitting" ? "Sending..." : "Send"}
        </Button>
        <Button onClick={onClose}>Cancel</Button>
      </section>
    </form>
  );
};
