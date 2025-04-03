import * as React from "react";

import { assert } from "$app/utils/assert";

import { useRefToLatest } from "./useRefToLatest";

const useKeyboardShortcut = ({ key }: { key: string }, cb: () => void) => {
  // The callback here is stashed into a reference to allow us to replace the callback
  // without tearing down & setting up a new event listener when the callback changes.
  const mostRecentCallbackRef = useRefToLatest(cb);

  React.useEffect(() => {
    const listener = (evt: KeyboardEvent) => {
      assert(evt.target instanceof HTMLElement);
      const isInAnInput = $(evt.target).filter("input, textarea").length > 0;
      if (evt.key === key && !isInAnInput) {
        const mostRecentCallback = mostRecentCallbackRef.current;
        mostRecentCallback();
      }
    };

    window.addEventListener("keydown", listener);
    return () => {
      window.removeEventListener("keydown", listener);
    };
  }, [key]);
};

export { useKeyboardShortcut };
