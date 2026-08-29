import * as React from "react";

import { classNames } from "$app/utils/classNames";

// On mobile, the product description sits above the purchase controls in a single-column layout,
// so a long description buries the price and CTA far down the page. We collapse tall descriptions
// behind a "Read more" toggle there. The collapse is purely CSS (max-height + overflow), so the
// full description HTML always stays in the DOM for SSR/SEO; desktop (lg and up) is never clamped
// because its two-column layout keeps the purchase sidebar visible alongside the description.
// Keep this in sync with the `max-h-[25rem]` Tailwind class below (25rem = 400px) — Tailwind
// can't interpolate a JS constant into a class name.
const MOBILE_DESCRIPTION_COLLAPSED_HEIGHT_PX = 400;
// Only collapse when the description meaningfully exceeds the collapsed height — clamping content
// that is barely taller would hide a few lines behind a toggle for no real gain.
const MOBILE_DESCRIPTION_COLLAPSE_THRESHOLD_PX = MOBILE_DESCRIPTION_COLLAPSED_HEIGHT_PX + 120;

export const CollapsibleDescription = ({ children }: { children: React.ReactNode }) => {
  const contentRef = React.useRef<HTMLDivElement | null>(null);
  const [isCollapsible, setIsCollapsible] = React.useState(false);
  const [isExpanded, setIsExpanded] = React.useState(false);

  React.useEffect(() => {
    const content = contentRef.current;
    if (!content) return;
    // The description's height changes as embeds/images load and on viewport resizes, so keep
    // re-checking whether it is tall enough to warrant collapsing instead of measuring once.
    const observer = new ResizeObserver(() => {
      setIsCollapsible(content.scrollHeight > MOBILE_DESCRIPTION_COLLAPSE_THRESHOLD_PX);
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, []);

  const isCollapsed = isCollapsible && !isExpanded;

  return (
    <>
      <div
        className={classNames(
          isCollapsed &&
            "max-h-[25rem] overflow-hidden [mask-image:linear-gradient(to_bottom,black_calc(100%_-_5rem),transparent)] lg:max-h-none lg:overflow-visible lg:[mask-image:none]",
        )}
      >
        <div ref={contentRef}>{children}</div>
      </div>
      {isCollapsible ? (
        <button
          className="mt-4 cursor-pointer underline all-unset lg:hidden"
          aria-expanded={isExpanded}
          onClick={() => setIsExpanded(!isExpanded)}
        >
          {isExpanded ? "Show less" : "Read more"}
        </button>
      ) : null}
    </>
  );
};
