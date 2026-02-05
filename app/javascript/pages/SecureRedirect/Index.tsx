import * as React from "react";
import { usePage, useForm } from "@inertiajs/react";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";

type SecureRedirectPageProps = {
  message: string;
  field_name: string;
  error_message: string;
  encrypted_payload: string;
  form_action: string;
  flash_error?: string | null;
};

function SecureRedirect() {
  const { message, field_name, error_message, encrypted_payload, form_action, flash_error } =
    usePage<SecureRedirectPageProps>().props;

  const { data, setData, post, processing, errors } = useForm({
    encrypted_payload,
    field_name,
    error_message,
    message,
    confirmation_text: "",
  });

  React.useEffect(() => {
    if (flash_error) {
      showAlert(flash_error, "error");
    }
  }, [flash_error]);

  React.useEffect(() => {
    if (errors.confirmation_text) {
      showAlert(errors.confirmation_text, "error");
    }
  }, [errors.confirmation_text]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();

    if (!data.confirmation_text.trim()) {
      showAlert("Please enter the confirmation text", "error");
      return;
    }

    post(form_action, {
      preserveScroll: true,
      onError: (errors) => {
        if (errors.error) {
          showAlert(errors.error, "error");
        } else {
          showAlert("An error occurred. Please try again.", "error");
        }
      },
    });
  };

  return (
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
          <label htmlFor="confirmation_text" className="form-label grow">
            {field_name}
          </label>
          <input
            id="confirmation_text"
            name="confirmation_text"
            type="text"
            placeholder={field_name}
            required
            value={data.confirmation_text}
            onChange={(e) => setData("confirmation_text", e.target.value)}
            disabled={processing}
          />
          <Button type="submit" color="primary" disabled={processing}>
            {processing ? "Processing..." : "Continue"}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export default SecureRedirect;
