import * as React from "react";

import { StripeConnectEmbeddedNotificationBanner } from "$app/components/PayoutPage/StripeConnectEmbeddedNotificationBanner";
import { Alert } from "$app/components/ui/Alert";
import { FormSection } from "$app/components/ui/FormSection";

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

  const isUnderReview = !!accountStatus.gumroad_status;
  const showStripeVerificationBanner = !accountStatus.is_suspended && showVerificationSection;

  const payoutPausedReason =
    payoutsPausedBy === "stripe" ? (
      <>
        Your payouts have been paused by the payment processor. If you have questions,{" "}
        <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
          contact support
        </a>
        .
      </>
    ) : payoutsPausedBy === "admin" ? (
      <>
        {`Your payouts have been paused by Gumroad.${payoutsPausedForReason ? ` ${payoutsPausedForReason}` : ""}`} If
        you have questions,{" "}
        <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
          contact support
        </a>
        .
      </>
    ) : payoutsPausedBy === "system" ? (
      <>
        Your payouts have been paused for a security review. If you have questions,{" "}
        <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
          contact support
        </a>
        .
      </>
    ) : payoutsPausedBy === "user" ? (
      isUnderReview ? (
        "You have paused your payouts."
      ) : (
        "You have paused your payouts. Use the pause payouts toggle below to resume."
      )
    ) : null;

  const showPayoutPausedAlert =
    !accountStatus.is_suspended && payoutPausedReason && (!showVerificationSection || payoutsPausedBy !== "stripe");

  return (
    <FormSection header={<h2>Account status</h2>}>
      <div className="flex flex-col gap-4">
        {showStripeVerificationBanner ? <StripeConnectEmbeddedNotificationBanner /> : null}

        {accountStatus.is_suspended && accountStatus.suspension_reason ? (
          <Alert role="status" variant="danger">
            {accountStatus.suspension_reason} If you have questions,{" "}
            <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
              contact support
            </a>
            .
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
                  <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
                    {action}
                  </a>
                </li>
              ))}
            </ul>
          </Alert>
        ) : null}

        {accountStatus.gumroad_status ? (
          <Alert role="status" variant="warning">
            {accountStatus.gumroad_status} If you have questions,{" "}
            <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
              contact support
            </a>
            .
          </Alert>
        ) : null}
      </div>
    </FormSection>
  );
}
