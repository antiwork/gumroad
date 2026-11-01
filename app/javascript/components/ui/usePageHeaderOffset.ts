import * as React from "react";

// A sticky page header paints over the sticky editor toolbar below it, since both anchor to the top
// of the scroll region. Publishing the header's measured height lets the toolbar offset itself by
// it; the height is not a constant because the header wraps at narrow widths.
export const usePageHeaderOffset = () => {
  const headerRef = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    const header = headerRef.current;
    const scroller = header?.parentElement;
    if (!header || !scroller) return;

    const publish = () => scroller.style.setProperty("--page-header-height", `${header.offsetHeight}px`);
    // Measure once up front rather than waiting for the observer's first callback; where
    // ResizeObserver is missing (happy-dom) that single measurement is what the toolbar reads.
    publish();
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(publish);
    observer?.observe(header);

    return () => {
      observer?.disconnect();
      scroller.style.removeProperty("--page-header-height");
    };
  }, []);

  return headerRef;
};
