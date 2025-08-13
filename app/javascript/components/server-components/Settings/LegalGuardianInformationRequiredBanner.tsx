import * as React from "react";

import { GuardianVerificationState } from "./PaymentsPage";

type Props = {
  status: GuardianVerificationState;
};

export const LegalGuardianInformationRequiredBanner = ({ status }: Props) => {
  switch (status) {
    case "requires_input":
      return (
        <div role="status" className="warning">
          <div className="flex flex-col gap-3 pb-3">
            <p>
              <strong>You're under 18</strong>, so we need your <strong>legal guardian's details</strong> to enable
              payments.
            </p>
            <div>
              <a
                href="#legal-guardian-section"
                className="hover:bg-gray-800 rounded bg-black px-4 py-2 text-sm font-medium text-white no-underline"
              >
                Add guardian details
              </a>
            </div>
          </div>
        </div>
      );

    case "pending":
      return (
        <div role="status" className="info">
          <p>
            <strong>Stripe is verifying your information.</strong>
            You'll get an email once the verification is complete. If additional information is needed, we'll contact
            your legal guardian directly.
          </p>
        </div>
      );

    case "verified":
      return null;

    default:
      return null;
  }
};
