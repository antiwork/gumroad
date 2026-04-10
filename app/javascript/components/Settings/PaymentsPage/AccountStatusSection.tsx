import * as React from "react";

import { StripeConnectEmbeddedNotificationBanner } from "$app/components/PayoutPage/StripeConnectEmbeddedNotificationBanner";
import { Alert } from "$app/components/ui/Alert";
import { FormSection } from "$app/components/ui/FormSection";

import logo from "$assets/images/logo-g.svg";

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
  userJoinedAt,
  locale,
}: {
  accountStatus: AccountStatus;
  payoutsPausedBy: "stripe" | "admin" | "system" | "user" | null;
  payoutsPausedForReason: string | null;
  showVerificationSection: boolean;
  userJoinedAt: string;
  locale: string;
}) {
  if (!accountStatus.show_section) return null;

  const payoutPausedReason =
    payoutsPausedBy === "stripe" ? (
      <>
        Your payouts have been paused by the payment processor.{" "}
        <a href="/settings/payments/remediation" className="underline">
          Complete pending verification requirements
        </a>{" "}
        to resolve this.
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
        {!accountStatus.is_suspended && showVerificationSection ? (
          <StripeConnectEmbeddedNotificationBanner />
        ) : !accountStatus.is_suspended && accountStatus.compliance_actions.length === 0 ? (
          <div className="flex flex-col">
            <Alert role="status" variant="success">
              Your identity has been verified!
            </Alert>
            <div className="mt-4 flex items-center">
              <img src={logo} alt="Gum Coin" className="mr-2 h-5 w-5" />
              <span className="text-sm text-muted">
                Creator since{" "}
                {new Date(userJoinedAt).toLocaleDateString(locale, {
                  month: "long",
                  day: "numeric",
                  year: "numeric",
                })}
              </span>
            </div>
          </div>
        ) : null}

        {accountStatus.is_suspended && accountStatus.suspension_reason ? (
          <Alert variant="danger">
            {accountStatus.suspension_reason} If you have questions,{" "}
            <a href="https://customers.gumroad.com/article/800-contact-support" className="underline">
              contact support
            </a>
            .
          </Alert>
        ) : null}

        {payoutPausedReason ? (
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
                  <a
                    href={
                      action === "Complete pending verification requirements via Stripe"
                        ? "/settings/payments/remediation"
                        : "https://customers.gumroad.com/article/800-contact-support"
                    }
                    className="underline"
                  >
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
