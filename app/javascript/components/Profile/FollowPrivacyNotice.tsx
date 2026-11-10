import * as React from "react";

import { classNames } from "$app/utils/classNames";

// Shown under the email field wherever a visitor can subscribe, so the notice is
// read at the point of collection instead of only in the footer.
export const FollowPrivacyNotice = ({ className }: { className?: string }) => (
  <p className={classNames("text-xs text-muted", className)}>
    We'll use your email to send you updates. See our{" "}
    <a href="https://gumroad.com/privacy" target="_blank" rel="noreferrer">
      Privacy Policy
    </a>
    .
  </p>
);
