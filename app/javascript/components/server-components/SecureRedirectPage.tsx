import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

type SecureRedirectPageProps = {
  message: string;
  field_name: string;
  error_message: string;
  encrypted_payload: string;
  form_action: string;
  authenticity_token: string;
  flash_error?: string | null;
};

type ErrorData = {
  error?: string;
};

const castToErrorData = createCast<ErrorData>();

const SecureRedirectPage = ({
  message,
  field_name,
  error_message,
  encrypted_payload,
  form_action,
  authenticity_token,
  flash_error,
}: SecureRedirectPageProps) => {
  const [confirmationText, setConfirmationText] = React.useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  React.useEffect(() => {
    if (flash_error) {
      showAlert(flash_error, "error");
    }
  }, [flash_error]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!confirmationText.trim()) {
      showAlert("Please enter your email address to unsubscribe", "error");
      return;
    }

    setIsSubmitting(true);

    try {
      const formData = new FormData();
      formData.append("authenticity_token", authenticity_token);
      formData.append("encrypted_payload", encrypted_payload);
      formData.append("field_name", field_name);
      formData.append("error_message", error_message);
      formData.append("message", message);
      formData.append("confirmation_text", confirmationText);

      const response = await fetch(form_action, {
        method: "POST",
        body: formData,
      });

      if (response.redirected) {
        window.location.href = response.url;
      } else if (!response.ok) {
        const errorData = castToErrorData(await response.json());
        showAlert(errorData.error || "An error occurred. Please try again.", "error");
      } else {
        showAlert("An error occurred. Please try again.", "error");
      }
    } catch (_error) {
      showAlert("An error occurred. Please try again.", "error");
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="stack single-page-form horizontal-form">
      <header>
        <h2>Confirm access</h2>
        <p>{message}</p>
      </header>
      <div className="mini-rule legacy-only"></div>
      <form
        onSubmit={(e) => {
          void handleSubmit(e);
        }}
      >
        <label htmlFor="confirmation_text" className="form-label">
          {field_name}
        </label>
        <input
          id="confirmation_text"
          name="confirmation_text"
          type="text"
          placeholder={field_name}
          required
          value={confirmationText}
          onChange={(e) => setConfirmationText(e.target.value)}
          disabled={isSubmitting}
        />
        <Button type="submit" color="primary" disabled={isSubmitting}>
          {isSubmitting ? "Processing..." : "Continue"}
        </Button>
      </form>
    </div>
  );
};

export default register({ component: SecureRedirectPage, propParser: createCast() });
