import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { asyncVoid } from "$app/utils/promise";
import { request, ResponseError } from "$app/utils/request";
import { getPasskey, isPasskeySupported, type PasskeyAuthenticationOptions } from "$app/utils/webauthn";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { Separator } from "$app/components/Separator";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";

const PASSKEY_ERROR = "We couldn't sign you in with that passkey. Please try again or use your password.";

type PageProps = {
  email: string | null;
  application_name: string | null;
  recaptcha_site_key: string | null;
  authenticity_token: string;
  show_passkey_login: boolean;
  is_gumroad_mobile_app: boolean;
};

type FormData = {
  user: {
    login_identifier: string;
    password: string;
  };
  next: string | null;
  "g-recaptcha-response": string | null;
  authenticity_token: string;
};

function LoginPage() {
  const {
    email: initialEmail,
    application_name,
    recaptcha_site_key,
    authenticity_token,
    show_passkey_login,
    is_gumroad_mobile_app,
  } = usePage<PageProps>().props;

  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next");
  const recaptcha = useRecaptcha({ siteKey: recaptcha_site_key });
  const uid = React.useId();

  const [passkeyLoading, setPasskeyLoading] = React.useState(false);
  const [passkeyError, setPasskeyError] = React.useState<string | null>(null);
  const [passkeySupported, setPasskeySupported] = React.useState(false);
  React.useEffect(() => setPasskeySupported(isPasskeySupported()), []);
  const showPasskeyButton = show_passkey_login && !is_gumroad_mobile_app && passkeySupported;

  const form = useForm<FormData>({
    user: {
      login_identifier: initialEmail ?? "",
      password: "",
    },
    next,
    "g-recaptcha-response": null,
    authenticity_token,
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

  const handlePasskeyLogin = asyncVoid(async () => {
    setPasskeyError(null);
    setPasskeyLoading(true);
    const csrfHeaders = { "X-CSRF-Token": authenticity_token };
    try {
      const optionsResponse = await request({
        url: Routes.login_passkey_options_path(),
        method: "POST",
        accept: "json",
        headers: csrfHeaders,
      });
      const optionsResult = typia.assert<{
        success: boolean;
        options?: PasskeyAuthenticationOptions;
        error_message?: string;
      }>(await optionsResponse.json());
      if (!optionsResponse.ok || !optionsResult.success || !optionsResult.options) {
        throw new ResponseError(optionsResult.error_message ?? PASSKEY_ERROR);
      }

      const credential = await getPasskey(optionsResult.options);

      const loginResponse = await request({
        url: Routes.login_passkey_path(),
        method: "POST",
        accept: "json",
        data: { credential, next },
        headers: csrfHeaders,
      });
      const loginResult = typia.assert<{ success: boolean; redirect_location?: string; error_message?: string }>(
        await loginResponse.json(),
      );
      if (!loginResponse.ok || !loginResult.success || !loginResult.redirect_location) {
        throw new ResponseError(loginResult.error_message ?? PASSKEY_ERROR);
      }

      window.location.href = loginResult.redirect_location;
    } catch (e) {
      if (e instanceof DOMException && (e.name === "NotAllowedError" || e.name === "AbortError")) return;
      setPasskeyError(e instanceof ResponseError ? e.message : PASSKEY_ERROR);
    } finally {
      setPasskeyLoading(false);
    }
  });

  return (
    <Layout
      header={<h1>{application_name ? `Connect ${application_name} to Gumroad` : "Log in"}</h1>}
      headerActions={<Link href={Routes.signup_path({ next })}>Sign up</Link>}
    >
      <form onSubmit={(e) => void handleSubmit(e)}>
        <SocialAuth />
        <Separator>
          <span>or</span>
        </Separator>
        <section className="grid gap-8 py-12">
          <AuthAlert />
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-email`}>Email</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-email`}
              type="email"
              value={form.data.user.login_identifier}
              onChange={(e) => form.setData("user.login_identifier", e.target.value)}
              required
              tabIndex={1}
              autoComplete="email"
            />
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-password`}>Password</Label>
              <Link href={Routes.new_user_password_path({ next })} className="font-normal underline">
                Forgot your password?
              </Link>
            </FieldsetTitle>
            <PasswordInput
              id={`${uid}-password`}
              value={form.data.user.password}
              onChange={(e) => form.setData("user.password", e.target.value)}
              required
              tabIndex={1}
              autoComplete="current-password"
            />
          </Fieldset>
          <div className="grid gap-4">
            <Button color="primary" type="submit" disabled={form.processing}>
              {form.processing ? "Logging in..." : "Login"}
            </Button>
            {showPasskeyButton ? (
              <>
                {passkeyError ? <Alert variant="danger">{passkeyError}</Alert> : null}
                <Button type="button" onClick={handlePasskeyLogin} disabled={passkeyLoading}>
                  {passkeyLoading ? "Waiting for passkey..." : "Log in with a passkey"}
                </Button>
              </>
            ) : null}
          </div>
        </section>
      </form>
      {recaptcha.container}
    </Layout>
  );
}

LoginPage.publicLayout = true;
export default LoginPage;
