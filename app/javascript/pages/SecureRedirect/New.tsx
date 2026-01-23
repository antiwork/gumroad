import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { AuthAlert } from "$app/components/AuthAlert";

type PageProps = {
  message: string;
  field_name: string;
  error_message: string;
  encrypted_payload: string;
  authenticity_token: string;
};

type FormData = {
  confirmation_text: string;
  encrypted_payload: string;
  authenticity_token: string;
  message: string;
  field_name: string;
  error_message: string;
};

function SecureRedirectNew() {
  const { message, field_name, error_message, encrypted_payload, authenticity_token } = usePage<PageProps>().props;
  const uid = React.useId();

  const form = useForm<FormData>({
    confirmation_text: "",
    encrypted_payload: encrypted_payload,
    authenticity_token: authenticity_token,
    message: message,
    field_name: field_name,
    error_message: error_message,
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.post(Routes.secure_url_redirect_path());
  };

  return (
    <Layout header={<h1>Security Check</h1>}>
      <form onSubmit={handleSubmit}>
        <section>
          <AuthAlert />
          <p className="text-subdued mb-4">{message}</p>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-confirmation-text`}>{field_name}</label>
            </legend>
            <input
              id={`${uid}-confirmation-text`}
              type="text"
              value={form.data.confirmation_text}
              onChange={(e) => form.setData("confirmation_text", e.target.value)}
              required
              autoFocus
              className="w-full"
            />
            {form.errors.confirmation_text && <div className="error-message">{form.errors.confirmation_text}</div>}
          </fieldset>

          <Button color="primary" type="submit" disabled={form.processing}>
            {form.processing ? "Verifying..." : "Continue"}
          </Button>
        </section>
      </form>
    </Layout>
  );
}

export default SecureRedirectNew;
