import * as React from "react";

import { StripeConnectEmbeddedNotificationBanner } from "$app/components/PayoutPage/StripeConnectEmbeddedNotificationBanner";
import { Alert } from "$app/components/ui/Alert";
import { FormSection } from "$app/components/ui/FormSection";

export type AccountStatus = {
  show_section: boolean;
  is_suspended: boolean;
  is_under_review: boolean;
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

  const payoutPausedReason =
    payoutsPausedBy === "stripe" ? (
      <>
        Your payouts have been paused by the payment processor. Complete pending verification requirements to resolve
        this.
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
      <strong>You have paused your payouts.</strong>
    ) : null;

  return (
    <FormSection header={<h2>Account status</h2>}>
      <div className="flex flex-col gap-4">
        {!accountStatus.is_suspended && showVerificationSection ? <StripeConnectEmbeddedNotificationBanner /> : null}

        {accountStatus.is_suspended && accountStatus.suspension_reason ? (
          <Alert variant="danger">
            {accountStatus.suspension_reason} If you have questions,{" "}
            <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
              contact support
            </a>
            .
          </Alert>
        ) : null}

        {!accountStatus.is_suspended && !showVerificationSection && payoutPausedReason ? (
          <Alert role="status" variant="warning">
            {payoutPausedReason}
          </Alert>
        ) : null}

        {!accountStatus.is_suspended && !showVerificationSection && accountStatus.compliance_actions.length > 0 ? (
          <Alert variant="warning">
            <strong>Action needed</strong>
            <ul className="mt-1 list-disc pl-4">
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

        {accountStatus.gumroad_status && (!payoutPausedReason || payoutsPausedBy === "user") ? (
          <Alert variant="warning">
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
