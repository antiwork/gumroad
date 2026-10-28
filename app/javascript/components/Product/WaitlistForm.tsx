import * as React from "react";

import { followSeller } from "$app/data/follow_seller";
import { isValidEmail } from "$app/utils/email";

import { Button } from "$app/components/Button";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Product } from "$app/components/Product";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import {
  RECAPTCHA_UNAVAILABLE_MESSAGE,
  RecaptchaCancelledError,
  RecaptchaDisclosure,
  RecaptchaUnavailableError,
  useRecaptcha,
} from "$app/components/useRecaptcha";

// The buy button's stand-in on a product that is not on sale yet. A signup is an ordinary follow
// of the seller plus a waitlist row for this product, so the visitor confirms their address by
// email exactly like a subscribe.
export const WaitlistForm = ({ product }: { product: Product }) => {
  const loggedInUser = useLoggedInUser();
  // The seller's own page and the editor preview keep the form visible with the button inactive —
  // a click there must not create a follower.
  const isOwner =
    product.can_edit ||
    product.waitlist_preview === true ||
    (loggedInUser !== null && loggedInUser.id === product.seller?.id);
  const [email, setEmail] = React.useState(isOwner ? "" : (loggedInUser?.email ?? ""));
  const [formStatus, setFormStatus] = React.useState<"initial" | "submitting" | "success" | "invalid">("initial");
  const [confirmed, setConfirmed] = React.useState(false);
  const [errorMessage, setErrorMessage] = React.useState<string | null>(null);
  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const recaptcha = useRecaptcha({ siteKey: product.follow_recaptcha_site_key ?? null });

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (isOwner || formStatus === "submitting") return;

    if (!isValidEmail(email)) {
      emailInputRef.current?.focus();
      setFormStatus("invalid");
      setErrorMessage(email.trim() === "" ? "Please enter your email address." : "Please enter a valid email address.");
      return;
    }

    setFormStatus("submitting");
    setErrorMessage(null);

    let recaptchaResponse: string | null = null;
    if (product.follow_recaptcha_site_key) {
      try {
        recaptchaResponse = await recaptcha.execute();
      } catch (error) {
        setFormStatus("initial");
        // Dismissing the challenge is a deliberate choice, so it needs no message; a CAPTCHA that
        // never loaded is something the visitor can fix, so it gets actionable guidance.
        if (error instanceof RecaptchaUnavailableError) setErrorMessage(RECAPTCHA_UNAVAILABLE_MESSAGE);
        else if (!(error instanceof RecaptchaCancelledError)) throw error;
        return;
      }
    }

    const response = await followSeller(email, product.seller?.id ?? "", recaptchaResponse, product.id);
    if (response.success) {
      setConfirmed(response.confirmed);
      setFormStatus("success");
    } else {
      setFormStatus("initial");
      setErrorMessage(response.message ?? "Sorry, something went wrong. Please try again.");
    }
  };

  if (formStatus === "success") {
    return (
      <Alert role="status" variant="success">
        {confirmed
          ? "You're on the list. We'll email you when it launches."
          : "You're on the list. Check your inbox to confirm."}
      </Alert>
    );
  }

  return (
    <form onSubmit={(e) => void submit(e)} noValidate>
      <Fieldset state={errorMessage ? "danger" : undefined}>
        <Input
          ref={emailInputRef}
          type="email"
          value={email}
          onChange={(event) => {
            setEmail(event.target.value);
            setFormStatus("initial");
            setErrorMessage(null);
          }}
          disabled={formStatus === "submitting"}
          placeholder="Your email address"
          aria-label="Your email address"
          aria-invalid={formStatus === "invalid"}
        />
        <Button className="w-full" color="primary" type="submit" disabled={isOwner || formStatus === "submitting"}>
          {formStatus === "submitting" ? "Adding you..." : "Notify me"}
        </Button>
        <FieldsetDescription>
          We'll email you when it launches. You'll also get updates from {product.seller?.name ?? ""}.
        </FieldsetDescription>
        {errorMessage ? (
          <FieldsetDescription role="alert" className="text-danger">
            {errorMessage}
          </FieldsetDescription>
        ) : null}
        {product.waitlist_count !== null ? (
          <FieldsetDescription>
            {product.waitlist_count} {product.waitlist_count === 1 ? "person is" : "people are"} on the waitlist.
          </FieldsetDescription>
        ) : null}
        {recaptcha.container}
        {product.follow_recaptcha_site_key != null ? <RecaptchaDisclosure /> : null}
      </Fieldset>
    </form>
  );
};
