import * as React from "react";

import { Alert } from "$app/components/ui/Alert";

// A normal auth visit resolves in about a second, so a submit still in flight after this long means
// the next page's JS chunk is not arriving on this connection, not that the server is slow.
const SLOW_CONNECTION_TIMEOUT_MS = 15_000;

type Props = {
  // Whether the form's Inertia visit is currently in flight (`form.processing`, or the page's own
  // submitting flag for visits started through `router`).
  processing: boolean;
};

export const SlowConnectionNotice: React.FC<Props> = ({ processing }) => {
  const [isSlow, setIsSlow] = React.useState(false);

  React.useEffect(() => {
    if (!processing) {
      setIsSlow(false);
      return;
    }

    const timer = setTimeout(() => setIsSlow(true), SLOW_CONNECTION_TIMEOUT_MS);
    return () => clearTimeout(timer);
  }, [processing]);

  if (!isSlow) return null;

  return (
    <Alert variant="warning">
      This is taking longer than usual — your connection may be too slow to load the next page.{" "}
      <a href={window.location.href} className="underline">
        Reload the page
      </a>{" "}
      to try again.
    </Alert>
  );
};
