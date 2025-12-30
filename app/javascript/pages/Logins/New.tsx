import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { ForgotPasswordForm } from "$app/components/Authentication/ForgotPasswordForm";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { Input } from "$app/components/Input";
import { PasswordInput } from "$app/components/PasswordInput";
import { Separator } from "$app/components/Separator";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";
import { WarningFlash } from "$app/components/WarningFlashMessage";

type PageProps = {
  email: string | null;
  application_name: string | null;
  recaptcha_site_key: string | null;
};

function LoginPage() {
  const { email: initialEmail, application_name, recaptcha_site_key } = usePage<PageProps>().props;

  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next");
  const recaptcha = useRecaptcha({ siteKey: recaptcha_site_key });
  const uid = React.useId();
  const [showForgotPassword, setShowForgotPassword] = React.useState(false);

  const form = useForm<{
    user: {
      login_identifier: string;
      password: string;
    };
    next: string | null;
    "g-recaptcha-response": string | null;
  }>({
    user: {
      login_identifier: initialEmail ?? "",
      password: "",
    },
    next,
    "g-recaptcha-response": null,
  });

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    try {
      const recaptchaResponse = recaptcha_site_key !== null ? await recaptcha.execute() : null;
      form.transform((data) => ({
        ...data,
        "g-recaptcha-response": recaptchaResponse,
      }));
      form.post(Routes.login_path());
    } catch (e) {
      if (e instanceof RecaptchaCancelledError) return;
      throw e;
    }
  };

  return (
    <Layout
      header={<h1>{application_name ? `Connect ${application_name} to Gumroad` : "Log in"}</h1>}
      headerActions={<Link href={Routes.signup_path({ next })}>Sign up</Link>}
    >
      {showForgotPassword ? (
        <ForgotPasswordForm onClose={() => setShowForgotPassword(false)} />
      ) : (
        <form className="flex flex-col gap-12" onSubmit={(e) => void handleSubmit(e)}>
          <SocialAuth />
          <Separator>
            <span>or</span>
          </Separator>
          <section className="flex flex-col gap-8">
            <WarningFlash />
            <fieldset>
              <legend className="mb-2">
                <label className="cursor-pointer" htmlFor={`${uid}-email`}>
                  Email
                </label>
              </legend>
              <Input
                id={`${uid}-email`}
                type="email"
                value={form.data.user.login_identifier}
                onChange={(e) => form.setData("user.login_identifier", e.target.value)}
                required
                tabIndex={1}
                autoComplete="email"
              />
            </fieldset>
            <fieldset>
              <legend className="mb-2 flex w-full justify-between">
                <label htmlFor={`${uid}-password`}>Password</label>
                <button type="button" className="underline" onClick={() => setShowForgotPassword(true)}>
                  Forgot your password?
                </button>
              </legend>
              <PasswordInput
                id={`${uid}-password`}
                value={form.data.user.password}
                onChange={(e) => form.setData("user.password", e.target.value)}
                required
                tabIndex={1}
                autoComplete="current-password"
              />
            </fieldset>
            <Button color="primary" type="submit" disabled={form.processing}>
              {form.processing ? "Logging in..." : "Login"}
            </Button>
          </section>
        </form>
      )}
      {recaptcha.container}
    </Layout>
  );
}

LoginPage.disableLayout = true;
export default LoginPage;
