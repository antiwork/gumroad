import cx from "classnames";
import * as React from "react";

import { followSeller } from "$app/data/follow_seller";
import { CreatorProfile } from "$app/parsers/profile";
import { classNames } from "$app/utils/classNames";
import { isValidEmail } from "$app/utils/email";

import { Button } from "$app/components/Button";
import { ButtonColor } from "$app/components/design";
import { Input } from "$app/components/Input";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";

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
    const response = await followSeller(email, creatorProfile.external_id);
    if (response.success) {
      setFormStatus("success");
      showAlert(response.message, "success");
    } else {
      showAlert("Sorry, something went wrong. Please try again.", "error");
      setFormStatus("initial");
    }
  };

  return (
    <form onSubmit={(e) => void submit(e)} style={{ flexGrow: 1 }} noValidate>
      <fieldset className={cx({ danger: formStatus === "invalid" })}>
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
      </fieldset>
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
