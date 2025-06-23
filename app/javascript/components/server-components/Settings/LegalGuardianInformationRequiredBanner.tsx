"use client";

import * as React from "react";

import { Icon } from "$app/components/Icons";

export function LegalGuardianInformationRequiredBanner() {
  return (
    <div className="mb-6 rounded-lg border-2 border-[#ff90e8] bg-white p-4 shadow-lg">
      <div className="flex items-start gap-3">
        <div className="mt-0.5 flex-shrink-0 rounded-full bg-[#ff90e8] p-1">
          <Icon name="shield-exclamation" className="h-4 w-4 text-black" />
        </div>
        <div className="flex-1">
          <h3 className="text-gray-900 mb-2 text-lg font-bold">Important notice for users under 18</h3>
          <div className="text-gray-700 space-y-3 text-sm leading-relaxed">
            <p>
              <strong>Since you are under 18, your legal guardian must be verified to enable card payments.</strong>
            </p>

            <div className="space-y-2">
              <p className="font-medium">Your legal guardian will need to:</p>
              <ul className="ml-2 list-inside list-disc space-y-1">
                <li>Provide their personal information</li>
                <li>Accept Stripe's terms of service</li>
                <li>Verify their identity with SSN (last 4 digits initially)</li>
              </ul>
            </div>

            <div className="bg-gray-50 rounded border-l-4 border-[#ff90e8] p-3">
              <p className="text-xs">
                <strong>Additional verification may be required:</strong> If initial verification fails, your guardian
                may need to provide their full SSN or upload ID documents (front and back).
              </p>
            </div>
            <a
              href="#legal-guardian-section"
              className="mt-3 inline-flex items-center gap-2 rounded bg-[#ff90e8] px-4 py-2 text-sm font-medium text-black transition-colors hover:bg-[#ff7ee0]"
            >
              Provide my legal guardian information
            </a>
          </div>
        </div>
      </div>
    </div>
  );
}
