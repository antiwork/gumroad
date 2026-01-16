import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type PageProps = {
  user_id: string;
  email: string;
  token: string | null;
};

function TwoFactorAuthentication() {
  const { user_id, email, token: initialToken } = usePage<PageProps>().props;
  const next = new URL(useOriginalLocation()).searchParams.get("next");
  const uid = React.useId();

  const form = useForm({
    token: initialToken ?? "",
    next,
  });

  const resendForm = useForm({});

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.post(Routes.two_factor_authentication_path({ user_id }));
  };

  const resendToken = () => {
    resendForm.post(Routes.resend_authentication_token_path({ user_id }));
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
      <form onSubmit={handleSubmit}>
        <section>
          <AuthAlert />
          <fieldset>
            <legend>
              <label htmlFor={uid}>Authentication Token</label>
            </legend>
            <input
              id={uid}
              type="text"
              value={form.data.token}
              onChange={(e) => form.setData("token", e.target.value)}
              required
              autoFocus
            />
          </fieldset>
          <Button color="primary" type="submit" disabled={form.processing}>
            {form.processing ? "Logging in..." : "Login"}
          </Button>
          <Button disabled={resendForm.processing} onClick={() => resendToken()}>
            Resend Authentication Token
          </Button>
        </section>
      </form>
    </Layout>
  );
}

TwoFactorAuthentication.disableLayout = true;
export default TwoFactorAuthentication;
