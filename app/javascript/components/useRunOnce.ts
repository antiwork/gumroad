import * as React from "react";

// Unlike useEffect, guarantees that the callback will actually only be run once.
//
// The callback must not return a cleanup function. This hook cannot honour one: the hasRun guard
// means the callback never runs a second time, so a cleanup that fired on unmount would tear down
// something nothing would ever rebuild. TypeScript cannot catch a returned cleanup here, because a
// function that returns a value is still assignable to a `() => void` parameter, so the mistake is
// invisible at the callsite — CopyToClipboard returned a ClipboardJS teardown from here for a long
// time and it simply never ran. Hence the runtime warning below.
//
// If you need setup that has to be undone on unmount, use a plain useEffect with a real dependency
// list instead of this hook.
export function useRunOnce(cb: () => void) {
  const hasRun = React.useRef(false);
  React.useEffect(() => {
    if (hasRun.current) return;
    const returned: unknown = cb();
    hasRun.current = true;

    if (process.env.NODE_ENV !== "production" && typeof returned === "function") {
      // eslint-disable-next-line no-console
      console.error(
        "useRunOnce: the callback returned a function, which looks like an effect cleanup. useRunOnce ignores it, so that cleanup will never run. Use a plain useEffect with a dependency list instead.",
      );
    }
  }, []);
}
