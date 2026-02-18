import { useForm } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";
import { classNames } from "$app/utils/classNames";
import { isValidEmail } from "$app/utils/email";

import { Button } from "$app/components/Button";
import { ButtonColor } from "$app/components/design";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";

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

  const form = useForm({
    email: isOwnProfile ? "" : (loggedInUser?.email ?? ""),
    seller_id: creatorProfile.external_id,
  });

  const followUser = (e: React.FormEvent) => {
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
    form.post(Routes.follow_user_path());
  };

  return (
    <form onSubmit={followUser} style={{ flexGrow: 1 }} noValidate>
      <fieldset className={cx({ danger: form.errors.email != null })}>
        <div className="flex gap-2">
          <input
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
      </fieldset>
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
