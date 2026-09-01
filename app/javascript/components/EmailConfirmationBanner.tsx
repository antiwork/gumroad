import * as React from "react";
import typia from "typia";

import { request } from "$app/utils/request";

import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { LinkButton } from "$app/components/ui/LinkButton";

export type EmailConfirmation = {
  email: string | null;
  can_resend: boolean;
};

type EmailConfirmationBannerProps = EmailConfirmation & {
  children?: React.ReactNode;
};

// Deliberately not dismissible: account confirmation gates real product actions, so the
// reminder stays up until the seller actually confirms.
export const EmailConfirmationBanner = ({ email, can_resend, children }: EmailConfirmationBannerProps) => {
  const [resendState, setResendState] = React.useState<"initial" | "sending" | "sent">("initial");

  const resendConfirmationEmail = async () => {
    setResendState("sending");
    try {
      const response = await request({
        method: "POST",
        url: Routes.resend_confirmation_email_settings_main_path(),
        accept: "json",
      });
      if (!response.ok) throw new Error();
      // The endpoint replies 200 with { success: false } when the resend was
      // rejected — the only rejection case is that there is nothing left to
      // confirm (e.g. the email was confirmed in another tab while the banner
      // was still up), so tell the seller that instead of a generic error.
      const responseData = typia.assert<{ success: boolean }>(await response.json());
      if (!responseData.success) {
        setResendState("initial");
        showAlert("Your email address is already confirmed — refresh the page to continue.", "error");
        return;
      }
      setResendState("sent");
    } catch {
      setResendState("initial");
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  };

  return (
    <Alert variant="warning">
      <span>
        {children ??
          (email ? (
            <>
              Please confirm your email address (<b>{email}</b>) — some features are unavailable until you do.
            </>
          ) : (
            <>Please add and confirm an email address — some features are unavailable until you do.</>
          ))}
        {email && can_resend ? (
          <>
            {" "}
            {resendState === "sent" ? (
              "Confirmation email sent!"
            ) : (
              <LinkButton
                disabled={resendState === "sending"}
                onClick={(e) => {
                  e.preventDefault();
                  void resendConfirmationEmail();
                }}
              >
                {resendState === "sending" ? "Resending..." : "Resend confirmation email"}
              </LinkButton>
            )}
          </>
        ) : null}
      </span>
    </Alert>
  );
};
