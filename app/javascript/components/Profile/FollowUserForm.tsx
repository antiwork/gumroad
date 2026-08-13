import { useForm } from "@inertiajs/react";
import * as React from "react";

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

export const FollowUserForm = ({
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
  const emailInputRef = React.useRef<HTMLInputElement>(null);
  // Non-null only for sellers we haven't reviewed yet, whose subscribe form has
  // to pass a CAPTCHA before we'll email the address (see FollowRecaptcha).
  const recaptchaSiteKey = creatorProfile.follow_recaptcha_site_key ?? null;
  const recaptcha = useRecaptcha({ siteKey: recaptchaSiteKey });

  const form = useForm({
    email: isOwnProfile ? "" : (loggedInUser?.email ?? ""),
    seller_id: creatorProfile.external_id,
    // Sent under the name Google's verification API expects, which is also what
    // the server reads it from. Stays empty when no challenge is required.
    "g-recaptcha-response": "",
  });

  const followUser = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isValidEmail(form.data.email)) {
      const message =
        form.data.email.trim() === "" ? "Please enter your email address." : "Please enter a valid email address.";
      form.setError("email", message);
      emailInputRef.current?.focus();
      showAlert(message, "error");
      return;
    }
    if (isOwnProfile) {
      showAlert("As the creator of this profile, you can't follow yourself!", "warning");
      return;
    }

    // The challenge has to resolve before the post, because the token travels
    // with it. Nothing submits if the visitor dismisses the challenge.
    if (recaptchaSiteKey) {
      let token: string;
      try {
        token = await recaptcha.execute();
      } catch (error) {
        // Dismissing the challenge is a deliberate choice, so it needs no error
        // message; a CAPTCHA that never loaded is something the visitor can fix,
        // so it gets actionable guidance.
        if (error instanceof RecaptchaUnavailableError) showAlert(RECAPTCHA_UNAVAILABLE_MESSAGE, "error");
        else if (!(error instanceof RecaptchaCancelledError)) throw error;
        return;
      }
      form.transform((data) => ({ ...data, "g-recaptcha-response": token }));
    }

    form.post(Routes.follow_user_path());
  };

  return (
    <form onSubmit={(e) => void followUser(e)} style={{ flexGrow: 1 }} noValidate>
      <Fieldset state={form.errors.email != null ? "danger" : undefined}>
        <div className="flex gap-2">
          <Input
            ref={emailInputRef}
            type="email"
            value={form.data.email}
            className="flex-1"
            onChange={(e) => {
              form.setData("email", e.target.value);
              form.clearErrors("email");
            }}
            placeholder="Your email address"
          />
          <Button color={buttonColor} disabled={form.processing || form.recentlySuccessful} type="submit">
            {buttonLabel && buttonLabel !== "Subscribe"
              ? buttonLabel
              : form.recentlySuccessful
                ? "Subscribed"
                : form.processing
                  ? "Subscribing..."
                  : "Subscribe"}
          </Button>
        </div>
        {recaptcha.container}
        {recaptchaSiteKey != null ? <RecaptchaDisclosure className="mt-2" /> : null}
      </Fieldset>
    </form>
  );
};

export const FollowUserFormBlock = ({
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
        <FollowUserForm creatorProfile={creatorProfile} buttonColor="primary" />
      </div>
    </div>
  </div>
);
