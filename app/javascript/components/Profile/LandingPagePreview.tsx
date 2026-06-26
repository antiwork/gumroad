import * as React from "react";

// Loads the same /:username/landing/embed document visitors see, so the preview
// reflects the live custom page instead of the default profile editor. The src is
// relative (same origin as the dashboard) so the embed's X-Frame-Options: SAMEORIGIN
// allows it. Unlike the product landing preview there's no checkout bridge — a
// profile has no buy button, so nothing posts back to the dashboard.
//
// ?preview makes the embed include a small listener so unsaved name/bio edits show
// live: the page's data-gumroad-field nodes are updated in place via postMessage,
// matching what a republish would interpolate server-side.
export const ProfileLandingPagePreview = ({
  username,
  name,
  bio,
}: {
  username: string;
  name: string | null;
  bio: string | null;
}) => {
  const frameRef = React.useRef<HTMLIFrameElement>(null);

  const postFields = React.useCallback(() => {
    frameRef.current?.contentWindow?.postMessage(
      { type: "gumroad:profile-fields", name: name ?? "", bio: bio ?? "" },
      "*",
    );
  }, [name, bio]);

  React.useEffect(postFields, [postFields]);

  return (
    <iframe
      ref={frameRef}
      title="Custom profile page preview"
      src={`/${encodeURIComponent(username)}/landing/embed?preview=true`}
      sandbox="allow-scripts allow-forms allow-popups"
      referrerPolicy="no-referrer"
      onLoad={postFields}
      className="h-[75vh] min-h-150 w-full rounded border border-border bg-white"
    />
  );
};
