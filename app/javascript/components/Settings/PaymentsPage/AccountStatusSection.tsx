import * as React from "react";

import { StripeConnectEmbeddedNotificationBanner } from "$app/components/PayoutPage/StripeConnectEmbeddedNotificationBanner";
import { Alert } from "$app/components/ui/Alert";

const CONTACT_SUPPORT_URL = "https://customers.gumroad.com/article/800-contact-support";

const SupportLink = () => (
  <>
    {" "}
    If you have questions,{" "}
    <a href={CONTACT_SUPPORT_URL} className="underline">
      contact support
    </a>
    .
  </>
);

export type AccountStatus = {
  show_section: boolean;
  is_suspended: boolean;
  suspension_reason: string | null;
  compliance_actions: string[];
  gumroad_status: string | null;
};

export default function AccountStatusSection({
  accountStatus,
  payoutsPausedBy,
  payoutsPausedForReason,
  showVerificationSection,
}: {
  accountStatus: AccountStatus;
  payoutsPausedBy: "stripe" | "admin" | "system" | "user" | null;
  payoutsPausedForReason: string | null;
  showVerificationSection: boolean;
}) {
  if (!accountStatus.show_section) return null;

  const showStripeVerificationBanner = !accountStatus.is_suspended && showVerificationSection;
  const normalizedPauseReason = payoutsPausedForReason?.trim().replace(/[.!?]+$/u, "") || null;

  const payoutPausedReason =
    payoutsPausedBy === "stripe" ? (
      <>
        Your payouts have been paused by the payment processor.
        <SupportLink />
      </>
    ) : payoutsPausedBy === "admin" ? (
      <>
        {`Your payouts have been paused by Gumroad.${normalizedPauseReason ? ` ${normalizedPauseReason}.` : ""}`}
        <SupportLink />
      </>
    ) : payoutsPausedBy === "system" ? (
      <>
        Your payouts have been paused for a security review.
        <SupportLink />
      </>
    ) : payoutsPausedBy === "user" ? (
      accountStatus.gumroad_status ? (
        "You have paused your payouts."
      ) : (
        "You have paused your payouts. Use the pause payouts toggle below to resume."
      )
    ) : null;

  const showPayoutPausedAlert =
    !accountStatus.is_suspended && payoutPausedReason && (!showVerificationSection || payoutsPausedBy !== "stripe");

  return (
    <div role="region" aria-labelledby="account-notices-heading" className="flex flex-col gap-4 p-4 md:p-8">
      <h2 id="account-notices-heading" className="sr-only">Account notices</h2>
      {showStripeVerificationBanner ? <StripeConnectEmbeddedNotificationBanner /> : null}

      {accountStatus.is_suspended && accountStatus.suspension_reason ? (
        <Alert role="status" variant="danger">
          {accountStatus.suspension_reason}
          <SupportLink />
        </Alert>
      ) : null}

      {showPayoutPausedAlert ? (
        <Alert role="status" variant="warning">
          {payoutPausedReason}
        </Alert>
      ) : null}

      {!accountStatus.is_suspended && !showVerificationSection && accountStatus.compliance_actions.length > 0 ? (
        <Alert role="status" variant="warning">
          <ul className="list-disc pl-4">
            {accountStatus.compliance_actions.map((action, i) => (
              <li key={i}>
                <a href={CONTACT_SUPPORT_URL} className="underline">
                  {action}
                </a>
              </li>
            ))}
          </ul>
        </Alert>
      ) : null}

      {accountStatus.gumroad_status ? (
        <Alert role="status" variant="warning">
          {accountStatus.gumroad_status}
          <SupportLink />
        </Alert>
      ) : null}
    </div>
  );
}
