import * as React from "react";
import { createCast } from "ts-safe-cast";

import { login } from "$app/data/login";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { ForgotPasswordForm } from "$app/components/Authentication/ForgotPasswordForm";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";

type SaveState = { type: "initial" | "submitting" } | { type: "error"; message: string };

export const LoginPage = ({
  email: initialEmail,
  application_name,
  recaptcha_site_key,
}: {
  email: string | null;
  application_name: string | null;
  recaptcha_site_key: string | null;
}) => {
  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next");
  const recaptcha = useRecaptcha({ siteKey: recaptcha_site_key });
  const uid = React.useId();
  const [email, setEmail] = React.useState(initialEmail ?? "");
  const [password, setPassword] = React.useState("");
  const [saveState, setSaveState] = React.useState<SaveState>({ type: "initial" });
  const [showForgotPassword, setShowForgotPassword] = React.useState(false);

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setSaveState({ type: "submitting" });
    try {
      const recaptchaResponse = recaptcha_site_key !== null ? await recaptcha.execute() : null;
      const { redirectLocation } = await login({
        email,
        password,
        recaptchaResponse,
        next,
      });
      window.location.href = redirectLocation;
    } catch (e) {
      if (e instanceof RecaptchaCancelledError) return setSaveState({ type: "initial" });
      assertResponseError(e);
      setSaveState({ type: "error", message: e.message });
    }
  };

  return (
    <Layout
      header={<h1>{application_name ? `Connect ${application_name} to Gumroad` : "Log in"}</h1>}
      headerActions={<a href={Routes.signup_path({ next })}>Sign up</a>}
    >
      {showForgotPassword ? (
        <ForgotPasswordForm onClose={() => setShowForgotPassword(false)} />
      ) : (
        <form onSubmit={(e) => void handleSubmit(e)}>
          <SocialAuth />
          <div role="separator">
            <span>or</span>
          </div>
          <section>
            {saveState.type === "error" ? (
              <div role="alert" className="danger">
                {saveState.message}
              </div>
            ) : null}
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-email`}>Email</label>
              </legend>
              <input
                id={`${uid}-email`}
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
                // We override the tabIndex to prevent the forgot password link interrupting the email -> password tab order
                tabIndex={1}
                autoComplete="email"
              />
            </fieldset>
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-password`}>Password</label>
                <button type="button" className="link" onClick={() => setShowForgotPassword(true)}>
                  Forgot your password?
                </button>
              </legend>
              <PasswordInput
                id={`${uid}-password`}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                tabIndex={1}
                autoComplete="current-password"
              />
            </fieldset>
            <Button color="primary" type="submit" disabled={saveState.type === "submitting"}>
              {saveState.type === "submitting" ? "Logging in..." : "Login"}
            </Button>
          </section>
        </form>
      )}
      {recaptcha.container}
    </Layout>
  );
};

export default register({ component: LoginPage, propParser: createCast() });
