import { router, useForm, usePage } from "@inertiajs/react";
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

function TwoFactorAuthentication() {
  const { user_id, email, token: initialToken, authenticity_token, two_factor_method } = usePage<PageProps>().props;
  const next = new URL(useOriginalLocation()).searchParams.get("next");
  const uid = React.useId();

  const switchForm = useForm({ authenticity_token });

  const isNumericCode = two_factor_method === "totp" || two_factor_method === "email";

  const [token, setToken] = React.useState(initialToken ?? "");
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  const submitCode = (token: string) => {
    if (isSubmitting) return;
    router.post(
      Routes.two_factor_authentication_path({ user_id }),
      { token, next, authenticity_token },
      {
        onBefore: () => setIsSubmitting(true),
        onFinish: () => setIsSubmitting(false),
      },
    );
  };

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    submitCode(token);
  };

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setToken(e.target.value);
    if (isNumericCode && /^\d{6}$/u.test(e.target.value)) submitCode(e.target.value);
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
              inputMode={isNumericCode ? "numeric" : "text"}
              autoComplete={isNumericCode ? "one-time-code" : undefined}
              maxLength={isNumericCode ? 6 : undefined}
              pattern={isNumericCode ? "[0-9]*" : undefined}
              value={token}
              onChange={handleChange}
              required
              autoFocus
              className={isNumericCode ? "tracking-[0.5em]" : undefined}
            />
          </Fieldset>
          <Button color="primary" type="submit" disabled={isSubmitting}>
            {isSubmitting ? "Logging in..." : "Login"}
          </Button>
          {(() => {
            switch (two_factor_method) {
              case "email":
                return (
                  <Button
                    disabled={switchForm.processing}
                    onClick={() => switchForm.post(Routes.resend_authentication_token_path({ user_id }))}
                  >
                    Resend Authentication Token
                  </Button>
                );
              case "totp":
                return (
                  <div className="flex gap-6">
                    <button
                      type="button"
                      className="cursor-pointer underline all-unset"
                      disabled={switchForm.processing}
                      onClick={() => switchForm.post(Routes.switch_to_email_two_factor_path({ user_id }))}
                    >
                      Use email instead
                    </button>
                    <button
                      type="button"
                      className="cursor-pointer underline all-unset"
                      disabled={switchForm.processing}
                      onClick={() => switchForm.post(Routes.switch_to_recovery_two_factor_path({ user_id }))}
                    >
                      Use a recovery code
                    </button>
                  </div>
                );
              case "recovery":
                return (
                  <div className="flex gap-6">
                    <button
                      type="button"
                      className="cursor-pointer underline all-unset"
                      disabled={switchForm.processing}
                      onClick={() => switchForm.post(Routes.switch_to_authenticator_two_factor_path({ user_id }))}
                    >
                      Use authenticator app
                    </button>
                    <button
                      type="button"
                      className="cursor-pointer underline all-unset"
                      disabled={switchForm.processing}
                      onClick={() => switchForm.post(Routes.switch_to_email_two_factor_path({ user_id }))}
                    >
                      Use email instead
                    </button>
                  </div>
                );
            }
          })()}
        </section>
      </form>
    </Layout>
  );
}

TwoFactorAuthentication.publicLayout = true;
export default TwoFactorAuthentication;
