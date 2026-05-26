import * as React from "react";

export const LandingPagePreview = ({ uniquePermalink }: { uniquePermalink: string }) => (
  <iframe
    title="Landing page preview"
    src={`/l/${encodeURIComponent(uniquePermalink)}/custom`}
    sandbox="allow-scripts allow-forms"
    referrerPolicy="no-referrer"
    className="h-[75vh] min-h-150 w-full rounded border border-border bg-white"
  />
);
