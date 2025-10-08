import * as React from "react";
import { createCast } from "ts-safe-cast";

import { resendTwoFactorToken, twoFactorLogin } from "$app/data/login";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type SaveState = { type: "initial" | "submitting" } | { type: "error"; message: string };

export const TwoFactorAuthenticationPage = ({
  user_id,
  email,
  token: initialToken,
}: {
  user_id: string;
  email: string;
  token: string | null;
}) => {
  const next = new URL(useOriginalLocation()).searchParams.get("next");
  const uid = React.useId();
  const [token, setToken] = React.useState(initialToken ?? "");
  const [loginState, setLoginState] = React.useState<SaveState>({ type: "initial" });
  const [resendState, setResendState] = React.useState<SaveState>({ type: "initial" });

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setLoginState({ type: "submitting" });
    try {
      const { redirectLocation } = await twoFactorLogin({ user_id, token, next });
      window.location.href = redirectLocation;
    } catch (e) {
      assertResponseError(e);
      setLoginState({ type: "error", message: e.message });
    }
  };

  const resendToken = async () => {
    setResendState({ type: "submitting" });
    try {
      await resendTwoFactorToken(user_id);
      showAlert("Resent the authentication token, please check your inbox.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setResendState({ type: "initial" });
  };

  return (
    <Layout
      header={
        <>
          <h1>Two-Factor Authentication</h1>
          <h3>
            To protect your account, we have sent an Authentication Token to {email}. Please enter it here to continue.
          </h3>
        </>
      }
    >
      <form onSubmit={(e) => void handleSubmit(e)}>
        <section>
          {loginState.type === "error" ? (
            <div role="alert" className="danger">
              {loginState.message}
            </div>
          ) : null}
          <fieldset>
            <legend>
              <label htmlFor={uid}>Authentication Token</label>
            </legend>
            <input id={uid} type="text" value={token} onChange={(e) => setToken(e.target.value)} required autoFocus />
          </fieldset>
          <Button color="primary" type="submit" disabled={loginState.type === "submitting"}>
            {loginState.type === "submitting" ? "Logging in..." : "Login"}
          </Button>
          <Button disabled={resendState.type === "submitting"} onClick={() => void resendToken()}>
            Resend Authentication Token
          </Button>
        </section>
      </form>
    </Layout>
  );
};

export default register({ component: TwoFactorAuthenticationPage, propParser: createCast() });
