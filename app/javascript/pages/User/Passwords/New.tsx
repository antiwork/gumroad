import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { Separator } from "$app/components/Separator";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type PageProps = {
  email: string | null;
  application_name: string | null;
};

function ForgotPasswordPage() {
  const { email: initialEmail, application_name } = usePage<PageProps>().props;
  const uid = React.useId();

  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next") || "dashboard";

  const form = useForm({
    user: {
      email: initialEmail ?? "",
    },
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.post(Routes.user_password_path());
  };

  return (
    <Layout
      header={<h1>{application_name ? `Connect ${application_name} to Gumroad` : "Forgot password"}</h1>}
      headerActions={<Link href={Routes.login_path({ next })}>Log in</Link>}
    >
      <form onSubmit={handleSubmit}>
        <SocialAuth />
        <Separator>
          <span>or</span>
        </Separator>
        <section>
          <AuthAlert />
          <fieldset>
            <legend>
              <label htmlFor={uid}>Email to send reset instructions to</label>
            </legend>
            <input
              id={uid}
              type="email"
              value={form.data.user.email}
              onChange={(e) => form.setData("user.email", e.target.value)}
              required
              autoFocus
              autoComplete="email"
            />
          </fieldset>
          <Button color="primary" type="submit" disabled={form.processing}>
            {form.processing ? "Sending..." : "Send"}
          </Button>
        </section>
      </form>
    </Layout>
  );
}

ForgotPasswordPage.disableLayout = true;
export default ForgotPasswordPage;
