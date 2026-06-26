import * as React from "react";

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
