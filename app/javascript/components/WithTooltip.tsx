import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type Position = "top" | "left" | "bottom" | "bottom-start" | "bottom-end" | "right";

const getPositionClasses = (position: Position) => {
  switch (position) {
    case "bottom-start":
      return {
        tooltip: "top-full translate-y-2 left-0",
        arrow: "bottom-full border-b-primary left-3",
      };
    case "bottom-end":
      return {
        tooltip: "top-full translate-y-2 right-0",
        arrow: "bottom-full border-b-primary right-3",
      };
    case "top":
      return {
        tooltip: "bottom-full -translate-y-2 left-1/2 -translate-x-1/2",
        arrow: "top-full border-t-primary left-1/2 -translate-x-1/2",
      };
    case "bottom":
      return {
        tooltip: "top-full translate-y-2 left-1/2 -translate-x-1/2",
        arrow: "bottom-full border-b-primary left-1/2 -translate-x-1/2",
      };
    case "left":
      return {
        tooltip: "right-full -translate-x-2 top-1/2 -translate-y-1/2",
        arrow: "left-full border-l-primary top-1/2 -translate-y-1/2",
      };
    case "right":
      return {
        tooltip: "left-full translate-x-2 top-1/2 -translate-y-1/2",
        arrow: "right-full border-r-primary top-1/2 -translate-y-1/2",
      };
  }
};

const getSide = (position: Position) => {
  if (position === "bottom-start" || position === "bottom-end") return "bottom";
  return position;
};

type Props = {
  children: React.ReactNode;
  tip: React.ReactNode | null;
  position?: Position | undefined;
  tooltipProps?: React.HTMLAttributes<HTMLSpanElement> | undefined;
} & React.HTMLAttributes<HTMLSpanElement>;

export const WithTooltip = ({ tip, children, position = "bottom", className, tooltipProps, ...props }: Props) => {
  const generatedId = React.useId();
  const id = tooltipProps?.id ?? generatedId;
  const contentRef = React.useRef<HTMLSpanElement>(null);
  const hasTip = Boolean(tip);
  React.useEffect(() => {
    const content = contentRef.current;
    if (!hasTip || !content) return;

    // Descriptions do not inherit through layout wrappers; associate the actual controls,
    // including controls rendered later by children, without cloning them or replacing refs.
    const ownedTargets = new Set<Element>();
    const descriptionIds = (element: Element) =>
      element.getAttribute("aria-describedby")?.split(/\s+/u).filter(Boolean) ?? [];
    const release = (element: Element) => {
      const remaining = descriptionIds(element).filter((value) => value !== id);
      if (remaining.length > 0) element.setAttribute("aria-describedby", remaining.join(" "));
      else element.removeAttribute("aria-describedby");
      ownedTargets.delete(element);
    };
    const sync = () => {
      const targets = new Set(
        content.querySelectorAll(
          'a[href], area[href], button, input, select, textarea, summary, [tabindex], [contenteditable]:not([contenteditable="false"])',
        ),
      );
      for (const element of ownedTargets) {
        if (!targets.has(element)) release(element);
      }
      for (const element of targets) {
        const existing = descriptionIds(element);
        if (existing.includes(id)) continue;
        element.setAttribute("aria-describedby", [...existing, id].join(" "));
        ownedTargets.add(element);
      }
    };
    sync();
    const observer = new MutationObserver(sync);
    observer.observe(content, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["aria-describedby", "tabindex", "href", "contenteditable"],
    });
    return () => {
      observer.disconnect();
      for (const element of ownedTargets) release(element);
    };
  }, [hasTip, id]);
  const positionClasses = getPositionClasses(position);

  return (
    <span {...props} className={classNames("group/tooltip relative inline-grid", className, getSide(position))}>
      <span ref={contentRef} aria-describedby={tip ? id : undefined} style={{ display: "contents" }}>
        {children}
      </span>
      {tip ? (
        <span
          role="tooltip"
          {...tooltipProps}
          id={id}
          className={classNames(
            "pointer-events-none absolute z-30 hidden w-40 max-w-max rounded-md bg-primary p-3 text-primary-foreground group-focus-within/tooltip:block group-hover/tooltip:block",
            positionClasses.tooltip,
            tooltipProps?.className,
          )}
        >
          <div className={classNames("absolute border-6 border-transparent", positionClasses.arrow)}></div>
          {tip}
        </span>
      ) : null}
    </span>
  );
};
