import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type TwoFactorMethod = "email" | "totp" | "recovery";

type PageProps = {
  user_id: string;
  email: string;
  token: string | null;
  authenticity_token: string;
  two_factor_method: TwoFactorMethod;
};

type FormData = {
  token: string;
  next: string | null;
  authenticity_token: string;
};

function TwoFactorAuthentication() {
  const { user_id, email, token: initialToken, authenticity_token, two_factor_method } =
    usePage<PageProps>().props;
  const next = new URL(useOriginalLocation()).searchParams.get("next");
  const uid = React.useId();

  const form = useForm<FormData>({
    token: initialToken ?? "",
    next,
    authenticity_token,
  });

  const switchForm = useForm({ authenticity_token });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.post(Routes.two_factor_authentication_path({ user_id }));
  };

  const resendToken = () => {
    switchForm.post(Routes.resend_authentication_token_path({ user_id }));
  };

  const switchToEmail = () => {
    switchForm.post(Routes.switch_to_email_two_factor_path({ user_id }));
  };

  const switchToRecovery = () => {
    switchForm.post(Routes.switch_to_recovery_two_factor_path({ user_id }));
  };

  const switchToAuthenticator = () => {
    switchForm.post(Routes.switch_to_authenticator_two_factor_path({ user_id }));
  };

  return (
    <Layout
      header={
        <>
          <h1>Two-Factor Authentication</h1>
          <h3>
            {two_factor_method === "totp"
              ? "Enter the code from your authenticator app."
              : two_factor_method === "recovery"
                ? "Enter one of your recovery codes."
                : `To protect your account, we have sent an Authentication Token to ${email}. Please enter it here to continue.`}
          </h3>
        </>
      }
    >
      <form onSubmit={handleSubmit}>
        <section className="grid gap-8 pb-12">
          <AuthAlert />
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={uid}>
                {two_factor_method === "totp"
                  ? "Authenticator Code"
                  : two_factor_method === "recovery"
                    ? "Recovery Code"
                    : "Authentication Token"}
              </Label>
            </FieldsetTitle>
            <Input
              id={uid}
              type="text"
              inputMode={two_factor_method === "recovery" ? "text" : "numeric"}
              value={form.data.token}
              onChange={(e) => form.setData("token", e.target.value)}
              required
              autoFocus
            />
          </Fieldset>
          <Button color="primary" type="submit" disabled={form.processing}>
            {form.processing ? "Logging in..." : "Login"}
          </Button>
          {two_factor_method === "email" ? (
            <Button disabled={switchForm.processing} onClick={() => resendToken()}>
              Resend Authentication Token
            </Button>
          ) : null}
          {two_factor_method === "totp" ? (
            <>
              <Button disabled={switchForm.processing} onClick={switchToEmail}>
                Use email instead
              </Button>
              <Button disabled={switchForm.processing} onClick={switchToRecovery}>
                Use a recovery code
              </Button>
            </>
          ) : null}
          {two_factor_method === "recovery" ? (
            <>
              <Button disabled={switchForm.processing} onClick={switchToAuthenticator}>
                Use authenticator app
              </Button>
              <Button disabled={switchForm.processing} onClick={switchToEmail}>
                Use email instead
              </Button>
            </>
          ) : null}
        </section>
      </form>
    </Layout>
  );
}

TwoFactorAuthentication.publicLayout = true;
export default TwoFactorAuthentication;
