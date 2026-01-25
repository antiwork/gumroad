import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Button } from "$app/components/Button";
import { Card, CardContent } from "$app/components/ui/Card";

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
    encrypted_payload,
    authenticity_token,
    message,
    field_name,
    error_message,
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    form.post(Routes.secure_url_redirect_path());
  };

  return (
    <>
      <Card className="single-page-form horizontal-form">
        <CardContent asChild>
          <header>
            <h2 className="grow">Confirm access</h2>
            <p>{message}</p>
          </header>
        </CardContent>
        <CardContent className="mini-rule legacy-only"></CardContent>
        <CardContent asChild>
          <form onSubmit={handleSubmit}>
            <AuthAlert />
            <label htmlFor={`${uid}-confirmation-text`} className="form-label grow">
              {field_name}
            </label>
            <input
              id={`${uid}-confirmation-text`}
              type="text"
              placeholder={field_name}
              value={form.data.confirmation_text}
              onChange={(e) => form.setData("confirmation_text", e.target.value)}
              required
              autoFocus
              disabled={form.processing}
            />
            {!!form.errors.confirmation_text && (
              <div className="error-message w-full">{form.errors.confirmation_text}</div>
            )}
            <Button color="primary" type="submit" disabled={form.processing}>
              {form.processing ? "Processing..." : "Continue"}
            </Button>
          </form>
        </CardContent>
      </Card>
      <footer className="text-subdued mt-8 text-center">
        Powered by <strong>Gumroad</strong>
      </footer>
    </>
  );
}

export default SecureRedirectNew;
