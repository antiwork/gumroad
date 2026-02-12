import cx from "classnames";
import * as React from "react";
import { useForm } from "@inertiajs/react";

import { CreatorProfile } from "$app/parsers/profile";
import { classNames } from "$app/utils/classNames";
import { isValidEmail } from "$app/utils/email";
import * as Routes from "$app/utils/routes";

import { Button } from "$app/components/Button";
import { ButtonColor } from "$app/components/design";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";

type FollowFormProps = {
  creatorProfile: CreatorProfile;
  buttonColor?: ButtonColor;
  buttonLabel?: string;
};

type FollowFormData = {
  email: string;
  seller_id: string;
};

export const FollowForm = ({ creatorProfile, buttonColor, buttonLabel }: FollowFormProps) => {
  const loggedInUser = useLoggedInUser();
  const isOwnProfile = loggedInUser?.id === creatorProfile.external_id;
  const emailInputRef = React.useRef<HTMLInputElement>(null);

  const { data, setData, post, processing } = useForm<FollowFormData>({
    email: isOwnProfile ? "" : (loggedInUser?.email ?? ""),
    seller_id: creatorProfile.external_id,
  });

  const [formStatus, setFormStatus] = React.useState<"initial" | "success" | "invalid">("initial");

  React.useEffect(() => setFormStatus("initial"), [data.email]);

  const submitForm = (e: React.FormEvent) => {
    e.preventDefault();

    if (!isValidEmail(data.email)) {
      emailInputRef.current?.focus();
      setFormStatus("invalid");
      showAlert(
        data.email.trim() === "" ? "Please enter your email address." : "Please enter a valid email address.",
        "error",
      );
      return;
    }

    if (isOwnProfile) {
      showAlert("As the creator of this profile, you can't follow yourself!", "warning");
      return;
    }

   post(Routes.follow_user_path(), {
      onSuccess: () => setFormStatus("success"),
    });
  };

  return (
    <form onSubmit={submitForm} style={{ flexGrow: 1 }} noValidate>
      <fieldset className={cx({ danger: formStatus === "invalid" })}>
        <div className="flex gap-2">
          <input
            ref={emailInputRef}
            type="email"
            value={data.email}
            className="flex-1"
            onChange={(event) => setData("email", event.target.value)}
            placeholder="Your email address"
          />
          <Button color={buttonColor} disabled={processing || formStatus === "success"} type="submit">
            {buttonLabel && buttonLabel !== "Subscribe"
              ? buttonLabel
              : formStatus === "success"
                ? "Subscribed"
                : processing
                  ? "Subscribing..."
                  : "Subscribe"}
          </Button>
        </div>
      </fieldset>
    </form>
  );
};

type FollowFormBlockProps = {
  creatorProfile: CreatorProfile;
  className?: string;
};

export const FollowFormBlock = ({ creatorProfile, className }: FollowFormBlockProps) => (
  <div className={classNames("flex grow flex-col justify-center", className)}>
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-16">
      <h1>Subscribe to receive email updates from {creatorProfile.name}.</h1>
      <div className="max-w-lg">
        <FollowForm creatorProfile={creatorProfile} buttonColor="primary" />
      </div>
    </div>
  </div>
);
