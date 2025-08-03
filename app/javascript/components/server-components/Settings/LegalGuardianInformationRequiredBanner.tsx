"use client";

import * as React from "react";

export function LegalGuardianInformationRequiredBanner() {
  return (
    <div role="status" className="warning">
      <div className="flex flex-col gap-3">
        <p>
          <strong>You're under 18</strong>, so we need your <strong>legal guardian's details</strong> to enable
          payments.
        </p>
        <a
          href="#legal-guardian-section"
          className="hover:bg-gray-800 self-start rounded bg-black px-4 py-2 text-sm font-medium text-white"
        >
          Add guardian details
        </a>
      </div>
    </div>
  );
}
