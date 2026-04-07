import * as React from "react";

import { Alert } from "$app/components/ui/Alert";
import { FormSection } from "$app/components/ui/FormSection";

export type AccountStatus = {
  show_section: boolean;
  account_state: string;
  is_suspended: boolean;
  is_under_review: boolean;
  suspension_reason: string | null;
  pending_compliance: boolean;
  compliance_actions: string[];
  gumroad_status: string | null;
};

const statusBadge = (accountStatus: AccountStatus) => {
  if (accountStatus.is_suspended) {
    return (
      <span className="inline-flex items-center rounded-full bg-danger/20 px-2 py-0.5 text-sm font-medium text-danger">
        Suspended
      </span>
    );
  }
  if (accountStatus.is_under_review) {
    return (
      <span className="inline-flex items-center rounded-full bg-warning/20 px-2 py-0.5 text-sm font-medium text-warning">
        Under Review
      </span>
    );
  }
  return (
    <span className="inline-flex items-center rounded-full bg-success/20 px-2 py-0.5 text-sm font-medium text-success">
      Active
    </span>
  );
};

export default function AccountStatusSection({
  accountStatus,
  payoutsPausedBy,
  payoutsPausedForReason,
}: {
  accountStatus: AccountStatus;
  payoutsPausedBy: "stripe" | "admin" | "system" | "user" | null;
  payoutsPausedForReason: string | null;
}) {
  if (!accountStatus.show_section) return null;

  const payoutPausedReason =
    payoutsPausedBy === "stripe"
      ? "Payouts paused by payment processor. Please check for pending verification requirements."
      : payoutsPausedBy === "admin"
        ? `Payouts paused by Gumroad.${payoutsPausedForReason ? ` Reason: ${payoutsPausedForReason}` : ""}`
        : payoutsPausedBy === "system"
          ? "Payouts paused for a security review."
          : null;

  return (
    <FormSection
      header={
        <div className="flex items-center gap-3">
          <h2>Account status</h2>
          {statusBadge(accountStatus)}
        </div>
      }
    >
      <div className="flex flex-col gap-4">
        {accountStatus.is_suspended && accountStatus.suspension_reason ? (
          <Alert variant="danger">{accountStatus.suspension_reason}</Alert>
        ) : null}

        {payoutPausedReason ? (
          <Alert variant="warning">
            <strong>Payout status: Paused</strong>
            <p>{payoutPausedReason}</p>
          </Alert>
        ) : null}

        {accountStatus.compliance_actions.length > 0 ? (
          <Alert variant="info">
            <strong>Action needed</strong>
            <ul className="mt-1 list-disc pl-4">
              {accountStatus.compliance_actions.map((action, i) => (
                <li key={i}>{action}</li>
              ))}
            </ul>
          </Alert>
        ) : null}

        {accountStatus.gumroad_status ? <Alert variant="info">{accountStatus.gumroad_status}</Alert> : null}
      </div>
    </FormSection>
  );
}
