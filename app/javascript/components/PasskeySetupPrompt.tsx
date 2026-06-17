import { usePage } from "@inertiajs/react";
import * as React from "react";

import { PASSKEY_ADD_ERROR, registerPasskey } from "$app/utils/passkeyRegistration";
import { asyncVoid } from "$app/utils/promise";
import { ResponseError } from "$app/utils/request";
import { isPasskeySupported } from "$app/utils/webauthn";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";

const SNOOZE_KEY_PREFIX = "passkeySetupPromptSnoozedUntil";
const SNOOZE_MS = 90 * 24 * 60 * 60 * 1000;

export const PasskeySetupPrompt = () => {
  const { authenticity_token, prompt_passkey_setup } = usePage<{
    authenticity_token: string;
    prompt_passkey_setup?: boolean;
  }>().props;
  const currentSeller = useCurrentSeller();
  const snoozeKey = `${SNOOZE_KEY_PREFIX}:${currentSeller?.id}`;
  const [supported, setSupported] = React.useState(false);
  const [dismissed, setDismissed] = React.useState(false);
  const [adding, setAdding] = React.useState(false);

  React.useEffect(() => setSupported(isPasskeySupported()), []);

  if (
    !prompt_passkey_setup ||
    !currentSeller ||
    !supported ||
    dismissed ||
    Number(localStorage.getItem(snoozeKey)) > Date.now()
  ) {
    return null;
  }

  const snooze = () => localStorage.setItem(snoozeKey, String(Date.now() + SNOOZE_MS));

  const dismiss = () => {
    snooze();
    setDismissed(true);
  };

  const handleSetup = asyncVoid(async () => {
    setAdding(true);
    try {
      await registerPasskey(authenticity_token);
      setDismissed(true);
      showAlert("You're set — next time, sign in with your passkey.", "success");
    } catch (e) {
      if (e instanceof DOMException && (e.name === "NotAllowedError" || e.name === "AbortError")) return;
      showAlert(e instanceof ResponseError ? e.message : PASSKEY_ADD_ERROR, "error");
    } finally {
      setAdding(false);
    }
  });

  return (
    <div className="px-4 pt-4 md:px-8 md:pt-8">
      <Alert variant="info" role="status">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="grid gap-1">
            <strong>Sign in faster, more securely</strong>
            <span>
              Use your fingerprint, face, or screen lock — no password to type. Your password still works too.
            </span>
          </div>
          <div className="flex gap-2">
            <Button color="accent" onClick={handleSetup} disabled={adding}>
              {adding ? "Waiting for passkey..." : "Set up a passkey"}
            </Button>
            <Button onClick={dismiss} disabled={adding}>
              Not now
            </Button>
          </div>
        </div>
      </Alert>
    </div>
  );
};
