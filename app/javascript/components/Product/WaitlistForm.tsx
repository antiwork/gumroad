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

type Waitlist = NonNullable<Product["waitlist"]>;

export const WaitlistForm = ({ product, waitlist }: { product: Product; waitlist: Waitlist }) => {
  const loggedInUser = useLoggedInUser();
  const [email, setEmail] = React.useState(product.can_edit ? "" : (loggedInUser?.email ?? ""));
  const [status, setStatus] = React.useState<
    | { type: "initial" }
    | { type: "submitting" }
    | { type: "error"; message: string }
    | { type: "joined"; message: string }
  >({ type: "initial" });
  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const errorId = React.useId();
  const recaptcha = useRecaptcha({ siteKey: waitlist.recaptcha_site_key });

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (product.can_edit || !product.seller) return;

    if (!isValidEmail(email)) {
      setStatus({
        type: "error",
        message: email.trim() === "" ? "Enter your email address." : "Enter a valid email address.",
      });
      emailInputRef.current?.focus();
      return;
    }

    setStatus({ type: "submitting" });

    let recaptchaResponse: string | null = null;
    if (waitlist.recaptcha_site_key) {
      try {
        recaptchaResponse = await recaptcha.execute();
      } catch (error) {
        if (error instanceof RecaptchaUnavailableError) {
          setStatus({ type: "error", message: RECAPTCHA_UNAVAILABLE_MESSAGE });
          return;
        }
        setStatus({ type: "initial" });
        if (!(error instanceof RecaptchaCancelledError)) throw error;
        return;
      }
    }

    const response = await followSeller(email, product.seller.id, recaptchaResponse, product.id);
    setStatus(
      response.success
        ? { type: "joined", message: response.message }
        : { type: "error", message: response.message ?? "Something went wrong. Try again." },
    );
  };

  return (
    <>
      <Alert role="status" variant="info">
        Coming soon
      </Alert>
      {status.type === "joined" ? (
        <Alert role="status" variant="success">
          {status.message}
        </Alert>
      ) : (
        <form onSubmit={(e) => void submit(e)} noValidate className="grid gap-4">
          <Fieldset state={status.type === "error" ? "danger" : undefined}>
            <Input
              ref={emailInputRef}
              type="email"
              value={email}
              onChange={(e) => {
                setEmail(e.target.value);
                if (status.type === "error") setStatus({ type: "initial" });
              }}
              placeholder="Your email address"
              aria-label="Email address"
              aria-invalid={status.type === "error"}
              aria-describedby={status.type === "error" ? errorId : undefined}
            />
            {status.type === "error" ? <FieldsetDescription id={errorId}>{status.message}</FieldsetDescription> : null}
          </Fieldset>
          <Button type="submit" color="accent" disabled={product.can_edit || status.type === "submitting"}>
            {status.type === "submitting" ? "Joining..." : "Notify me"}
          </Button>
          <p className="text-sm">
            {product.seller?.name} will email you when it launches. You'll also get their other updates.
          </p>
          {recaptcha.container}
          {waitlist.recaptcha_site_key ? <RecaptchaDisclosure /> : null}
        </form>
      )}
      {product.can_edit && waitlist.count !== null ? (
        <p className="text-sm">
          Only you see this: {waitlist.count.toLocaleString()} {waitlist.count === 1 ? "person is" : "people are"} on
          the waitlist.
        </p>
      ) : null}
    </>
  );
};
