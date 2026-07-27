import * as React from "react";

// Unlike useEffect, guarantees that the callback will actually only be run once.
//
// A callback may return a cleanup function, which runs when the component unmounts — the same
// contract useEffect has. Honoring it matters because the "run once" guarantee is what makes
// callers reach for this hook to set up long-lived objects (event listeners, ClipboardJS
// instances), and those need tearing down. Before this returned value was passed through, the
// cleanup was silently dropped and every such object leaked for the page's lifetime.
//
// Note the cleanup only ever runs on unmount, never on a re-render: the effect deliberately has
// an empty dependency list and the ref guard keeps the body from running a second time.
export function useRunOnce(cb: () => undefined | (() => void)) {
  const hasRun = React.useRef(false);
  const cleanupRef = React.useRef<(() => void) | undefined>(undefined);
  React.useEffect(() => {
    if (!hasRun.current) {
      cleanupRef.current = cb();
      hasRun.current = true;
    }
    return () => cleanupRef.current?.();
  }, []);
}
