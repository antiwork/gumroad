import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";

type PageProps = {
  reset_password_token: string;
};

function PasswordReset() {
  const { reset_password_token } = usePage<PageProps>().props;
  const uid = React.useId();

  const form = useForm({
    user: {
      password: "",
      password_confirmation: "",
      reset_password_token,
    },
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.put(Routes.user_password_path());
  };

  return (
    <Layout header={<h1>Reset your password</h1>} headerActions={<Link href={Routes.login_path()}>Log in</Link>}>
      <form onSubmit={handleSubmit}>
        <section>
          <AuthAlert />
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-password`}>Enter a new password</label>
            </legend>
            <PasswordInput
              id={`${uid}-password`}
              value={form.data.user.password}
              onChange={(e) => form.setData("user.password", e.target.value)}
              placeholder="Password"
              required
              autoFocus
              autoComplete="new-password"
            />
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-password-confirmation`}>Enter same password to confirm</label>
            </legend>
            <PasswordInput
              id={`${uid}-password-confirmation`}
              value={form.data.user.password_confirmation}
              onChange={(e) => form.setData("user.password_confirmation", e.target.value)}
              placeholder="Password (to confirm)"
              required
              autoComplete="new-password"
            />
          </fieldset>
          <Button color="primary" type="submit" disabled={form.processing}>
            {form.processing ? "Resetting..." : "Reset password"}
          </Button>
        </section>
      </form>
    </Layout>
  );
}

PasswordReset.disableLayout = true;
export default PasswordReset;
