import * as React from "react";

// Unlike useEffect, guarantees that the callback will actually only be run once.
//
// The callback must not return a cleanup function. This hook cannot honour one: the hasRun guard
// makes the callback run at most once for the life of the component, so there is no re-setup to
// pair a teardown with, and under StrictMode's deliberate effect replay the guard would suppress
// the second setup while a cleanup had already torn the first one down. TypeScript cannot catch a
// returned cleanup here either, because a function that returns a value is still assignable to a
// `() => void` parameter, so the mistake is invisible at the callsite — CopyToClipboard returned a
// ClipboardJS teardown from here for a long time and it simply never ran. Hence the runtime
// warning below.
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
