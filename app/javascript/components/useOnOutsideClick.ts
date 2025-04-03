import * as React from "react";

import { isElementWithin } from "$app/utils/isElementWithin";

import { useGlobalEventListener } from "$app/components/useGlobalEventListener";

// `els` is a white-list of elements that should receive clicks without triggering `callback`
export const useOnOutsideClick = (
  elsAndRefs: (HTMLElement | null | React.RefObject<HTMLElement>)[],
  callback: () => void,
) => {
  useGlobalEventListener("mouseup", (evt) => {
    const els: (HTMLElement | null)[] = elsAndRefs.map((elOrRef) => {
      if (elOrRef == null) return null;
      if ("current" in elOrRef) return elOrRef.current;
      return elOrRef;
    });
    if (!(evt.target instanceof HTMLElement)) return;
    if (!isElementWithin(evt.target, els)) {
      callback();
    }
  });
};
