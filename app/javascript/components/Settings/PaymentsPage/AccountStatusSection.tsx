import * as React from "react";

import { Alert } from "$app/components/ui/Alert";

const HELP_URL = "https://help.gumroad.com";

const SupportLink = () => (
  <>
    {" "}
    If you have questions,{" "}
    <a href={HELP_URL} className="underline">
      contact support
    </a>
    .
  </>
);

export type ComplianceAction = { message: string; href: string | null };

const ComplianceActionItem = ({ action }: { action: ComplianceAction }) =>
  action.href ? (
    <a href={action.href} className="underline">
      {action.message}
    </a>
  ) : (
    action.message
  );

export type AccountStatus = {
  show_section: boolean;
  is_suspended: boolean;
  suspension_reason: string | null;
  compliance_actions: ComplianceAction[];
  gumroad_status: string | null;
};

export default function AccountStatusSection({
  accountStatus,
  payoutsPausedBy,
}: {
  accountStatus: AccountStatus;
  payoutsPausedBy: "stripe" | "admin" | "system" | "user" | null;
}) {
  if (!accountStatus.show_section) return null;

  const payoutPausedReason =
    payoutsPausedBy === "stripe" ? (
      <>
        Your payouts have been paused by Stripe.
        <SupportLink />
      </>
    ) : payoutsPausedBy === "admin" ? (
      <>
        Your payouts have been paused by Gumroad.
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

  const showPayoutPausedAlert = !accountStatus.is_suspended && payoutPausedReason;

  return (
    <section aria-labelledby="account-status-heading" className="flex flex-col gap-4 p-4 md:p-8">
      <h2 id="account-status-heading" className="sr-only">
        Account status
      </h2>

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

      {!accountStatus.is_suspended && accountStatus.compliance_actions.length > 0 ? (
        <Alert role="status" variant="warning">
          <div className="flex flex-col gap-1">
            {accountStatus.compliance_actions.map((action, i) => (
              <ComplianceActionItem key={i} action={action} />
            ))}
            {accountStatus.compliance_actions.some((a) => !a.href) ? (
              <p>
                Please update your information below.
                <SupportLink />
              </p>
            ) : null}
          </div>
        </Alert>
      ) : null}

      {accountStatus.gumroad_status && (!showPayoutPausedAlert || payoutsPausedBy !== "system") ? (
        <Alert role="status" variant="warning">
          {accountStatus.gumroad_status}
          <SupportLink />
        </Alert>
      ) : null}
    </section>
  );
}
