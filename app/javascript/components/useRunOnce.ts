import * as React from "react";

// Unlike useEffect, guarantees that the callback will actually only be run once.
export function useRunOnce(cb: () => void) {
  const hasRun = React.useRef(false);
  React.useEffect(() => {
    if (hasRun.current) return;
    cb();
    hasRun.current = true;
  }, []);
}
