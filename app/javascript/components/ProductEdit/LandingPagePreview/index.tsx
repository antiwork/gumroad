import * as React from "react";

// Loads the same /l/:id/landing endpoint buyers see. The sandbox omits
// top-navigation (mirrors the production wrapper) so the seller's HTML can't
// navigate the dashboard tab. The buy button posts "gumroad:checkout" to this
// parent, which opens checkout in a new tab so the seller can test the button
// without being yanked out of the editor.
export const LandingPagePreview = ({ uniquePermalink }: { uniquePermalink: string }) => {
  const frameRef = React.useRef<HTMLIFrameElement>(null);

  React.useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      // Only our own iframe can request checkout — gate on e.source so another
      // window can't drive the dashboard. The iframe's sandbox has no
      // allow-same-origin, so e.origin is "null" and isn't a usable check.
      if (e.source === frameRef.current?.contentWindow && e.data === "gumroad:checkout")
        window.open(`/l/${encodeURIComponent(uniquePermalink)}?wanted=true`, "_blank", "noopener");
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [uniquePermalink]);

  return (
    <iframe
      ref={frameRef}
      title="Landing page preview"
      src={`/l/${encodeURIComponent(uniquePermalink)}/landing/embed`}
      sandbox="allow-scripts allow-forms"
      referrerPolicy="no-referrer"
      className="h-[75vh] min-h-150 w-full rounded border border-border bg-white"
    />
  );
};
