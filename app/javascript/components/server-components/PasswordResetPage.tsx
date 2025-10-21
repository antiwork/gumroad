import * as React from "react";
import { createCast, cast } from "ts-safe-cast";

import { request, ResponseError, assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { showAlert } from "$app/components/server-components/Alert";

export const PasswordResetPage = ({ reset_password_token }: { reset_password_token: string }) => {
  const uid = React.useId();
  const [password, setPassword] = React.useState("");
  const [passwordConfirmation, setPasswordConfirmation] = React.useState("");
  const [submitting, setSubmitting] = React.useState(false);

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      const response = await request({
        method: "PUT",
        accept: "json",
        url: Routes.user_password_path(),
        data: {
          user: {
            password,
            password_confirmation: passwordConfirmation,
            reset_password_token,
          },
        },
      });
      if (!response.ok) {
        const json = cast<{ error_message?: string }>(await response.json());
        throw new ResponseError(json.error_message || "Failed to reset password");
      }
      window.location.href = Routes.root_path();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  return (
    <Layout header={<h1>Reset your password</h1>} headerActions={<a href={Routes.login_path()}>Log in</a>}>
      <form onSubmit={(e) => void handleSubmit(e)}>
        <section>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-password`}>Enter a new password</label>
            </legend>
            <PasswordInput
              id={`${uid}-password`}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
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
              value={passwordConfirmation}
              onChange={(e) => setPasswordConfirmation(e.target.value)}
              placeholder="Password (to confirm)"
              required
              autoComplete="new-password"
            />
          </fieldset>
          <Button color="primary" type="submit" disabled={submitting}>
            Reset password
          </Button>
        </section>
      </form>
    </Layout>
  );
};

export default register({ component: PasswordResetPage, propParser: createCast() });
