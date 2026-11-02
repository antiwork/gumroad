import * as React from "react";

// A sticky page header paints over the sticky editor toolbar below it, since both anchor to the top
// of the scroll region. Publishing the header's measured height lets the toolbar offset itself by
// it; the height is not a constant because the header wraps at narrow widths.
export const usePageHeaderOffset = () => {
  const cleanupRef = React.useRef<(() => void) | null>(null);

  // A callback ref rather than an effect: a page can render its header in only one of several
  // branches, so the height has to be measured whenever the header appears, not only on mount.
  return React.useCallback((header: HTMLDivElement | null) => {
    cleanupRef.current?.();
    cleanupRef.current = null;

    const scroller = header?.parentElement;
    if (!header || !scroller) return;

    const publish = () => scroller.style.setProperty("--page-header-height", `${header.offsetHeight}px`);
    // Measure once up front rather than waiting for the observer's first callback; where
    // ResizeObserver is missing (happy-dom) that single measurement is what the toolbar reads.
    publish();
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(publish);
    observer?.observe(header);

    cleanupRef.current = () => {
      observer?.disconnect();
      scroller.style.removeProperty("--page-header-height");
    };
  }, []);
};
