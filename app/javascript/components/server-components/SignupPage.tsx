import * as React from "react";
import { createCast } from "ts-safe-cast";

import { createAccount } from "$app/data/account";
import { formatPrice } from "$app/utils/price";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";

type SaveState = { type: "initial" | "submitting" } | { type: "error"; message: string };

export const SignupPage = ({
  email: initialEmail,
  application_name,
  referrer,
  stats: { number_of_creators, total_made },
  recaptcha_site_key,
}: {
  email: string | null;
  application_name: string | null;
  referrer: {
    id: string;
    name: string;
  } | null;
  stats: {
    number_of_creators: number;
    total_made: number;
  };
  recaptcha_site_key: string | null;
}) => {
  const next = new URL(useOriginalLocation()).searchParams.get("next");
  const recaptcha = useRecaptcha({ siteKey: recaptcha_site_key });
  const uid = React.useId();
  const [email, setEmail] = React.useState(initialEmail ?? "");
  const [password, setPassword] = React.useState("");
  const [saveState, setSaveState] = React.useState<SaveState>({ type: "initial" });

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setSaveState({ type: "submitting" });
    try {
      const recaptchaResponse = recaptcha_site_key !== null ? await recaptcha.execute() : null;
      const { redirectLocation } = await createAccount({
        email,
        password,
        recaptchaResponse,
        termsAccepted: true,
        next,
        referrerId: referrer?.id ?? null,
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
      header={
        <h1>
          {referrer
            ? `Join ${referrer.name} on Gumroad`
            : application_name
              ? `Sign up for Gumroad and connect ${application_name}`
              : `Join over ${number_of_creators.toLocaleString()} creators who have earned over ${formatPrice("$", total_made, 0, { noCentsIfWhole: true })} on Gumroad selling digital products and memberships.`}
        </h1>
      }
      headerActions={<a href={Routes.login_path({ next })}>Log in</a>}
    >
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
            <input id={`${uid}-email`} type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-password`}>Password</label>
            </legend>
            <PasswordInput
              id={`${uid}-password`}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </fieldset>
          <Button color="primary" type="submit" disabled={saveState.type === "submitting"}>
            {saveState.type === "submitting" ? "Creating..." : "Create account"}
          </Button>
          <p>
            You agree to our <a href="https://gumroad.com/terms">Terms of Use</a> and{" "}
            <a href="https://gumroad.com/privacy">Privacy Policy</a>.
          </p>
        </section>
      </form>
      {recaptcha.container}
    </Layout>
  );
};

export default register({ component: SignupPage, propParser: createCast() });
