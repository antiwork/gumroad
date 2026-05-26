import * as React from "react";

// Loads the same /l/:id/landing endpoint buyers see, so the preview matches
// production exactly. `allow-top-navigation-by-user-activation` lets buy
// buttons navigate the dashboard to checkout instead of being dead clicks.
export const LandingPagePreview = ({ uniquePermalink }: { uniquePermalink: string }) => (
  <iframe
    title="Landing page preview"
    src={`/l/${encodeURIComponent(uniquePermalink)}/landing`}
    sandbox="allow-scripts allow-forms allow-top-navigation-by-user-activation"
    referrerPolicy="no-referrer"
    className="h-[75vh] min-h-150 w-full rounded border border-border bg-white"
  />
);
