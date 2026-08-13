import * as React from "react";

import { followSeller } from "$app/data/follow_seller";
import { CreatorProfile } from "$app/parsers/profile";
import { classNames } from "$app/utils/classNames";
import { isValidEmail } from "$app/utils/email";

import { Button } from "$app/components/Button";
import { ButtonColor } from "$app/components/design";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import {
  RECAPTCHA_UNAVAILABLE_MESSAGE,
  RecaptchaCancelledError,
  RecaptchaDisclosure,
  RecaptchaUnavailableError,
  useRecaptcha,
} from "$app/components/useRecaptcha";

export const FollowForm = ({
  creatorProfile,
  buttonColor,
  buttonLabel,
}: {
  creatorProfile: CreatorProfile;
  buttonColor?: ButtonColor;
  buttonLabel?: string;
}) => {
  const loggedInUser = useLoggedInUser();
  const isOwnProfile = loggedInUser?.id === creatorProfile.external_id;
  const [email, setEmail] = React.useState(isOwnProfile ? "" : (loggedInUser?.email ?? ""));
  const [formStatus, setFormStatus] = React.useState<"initial" | "submitting" | "success" | "invalid">("initial");
  const emailInputRef = React.useRef<HTMLInputElement>(null);
  // Non-null only for sellers we haven't reviewed yet, whose subscribe form has
  // to pass a CAPTCHA before we'll email the address (see FollowRecaptcha).
  const recaptcha = useRecaptcha({ siteKey: creatorProfile.follow_recaptcha_site_key ?? null });

  React.useEffect(() => setFormStatus("initial"), [email]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!isValidEmail(email)) {
      emailInputRef.current?.focus();
      setFormStatus("invalid");
      showAlert(
        email.trim() === "" ? "Please enter your email address." : "Please enter a valid email address.",
        "error",
      );
      return;
    }

    if (isOwnProfile) {
      showAlert("As the creator of this profile, you can't follow yourself!", "warning");
      return;
    }

    setFormStatus("submitting");

    let recaptchaResponse: string | null = null;
    if (creatorProfile.follow_recaptcha_site_key) {
      try {
        recaptchaResponse = await recaptcha.execute();
      } catch (error) {
        setFormStatus("initial");
        // Dismissing the challenge is a deliberate choice, so it needs no error
        // message; a CAPTCHA that never loaded is something the visitor can fix,
        // so it gets actionable guidance.
        if (error instanceof RecaptchaUnavailableError) showAlert(RECAPTCHA_UNAVAILABLE_MESSAGE, "error");
        else if (!(error instanceof RecaptchaCancelledError)) throw error;
        return;
      }
    }

    const response = await followSeller(email, creatorProfile.external_id, recaptchaResponse);
    if (response.success) {
      setFormStatus("success");
      showAlert(response.message, "success");
    } else {
      showAlert(response.message ?? "Sorry, something went wrong. Please try again.", "error");
      setFormStatus("initial");
    }
  };

  return (
    <form onSubmit={(e) => void submit(e)} style={{ flexGrow: 1 }} noValidate>
      <Fieldset state={formStatus === "invalid" ? "danger" : undefined}>
        <div className="flex gap-2">
          <Input
            ref={emailInputRef}
            type="email"
            value={email}
            className="flex-1"
            onChange={(event) => setEmail(event.target.value)}
            placeholder="Your email address"
          />
          <Button color={buttonColor} disabled={formStatus === "submitting" || formStatus === "success"} type="submit">
            {buttonLabel && buttonLabel !== "Subscribe"
              ? buttonLabel
              : formStatus === "success"
                ? "Subscribed"
                : formStatus === "submitting"
                  ? "Subscribing..."
                  : "Subscribe"}
          </Button>
        </div>
        {recaptcha.container}
        {creatorProfile.follow_recaptcha_site_key != null ? <RecaptchaDisclosure className="mt-2" /> : null}
      </Fieldset>
    </form>
  );
};

export const FollowFormBlock = ({
  creatorProfile,
  className,
}: {
  creatorProfile: CreatorProfile;
  className?: string;
}) => (
  <div className={classNames("flex grow flex-col justify-center", className)}>
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-16">
      <h1>Subscribe to receive email updates from {creatorProfile.name}.</h1>
      <div className="max-w-lg">
        <FollowForm creatorProfile={creatorProfile} buttonColor="primary" />
      </div>
    </div>
  </div>
);
