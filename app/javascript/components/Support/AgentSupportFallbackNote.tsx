import * as React from "react";

import { SUPPORT_EMAIL } from "$app/components/Support/ContactSupportModal";

// Shown on every surface where an AI agent is the way to build or change a
// page. Sellers who don't want to use an agent, or whose agent-built page
// didn't come out right, had no visible way forward and only learned support
// can make the change by hand after complaining over email. This note puts
// that path in the product itself.
export const AgentSupportFallbackNote = ({ subject }: { subject: string }) => (
  <p className="text-sm text-muted">
    Something not working, or want a change you'd rather not do with an agent? Email{" "}
    <a href={`mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent(subject)}`}>{SUPPORT_EMAIL}</a> and we'll take care
    of it for you.
  </p>
);
