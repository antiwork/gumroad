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
  const id = React.useId();
  const positionClasses = getPositionClasses(position);

  return (
    <span {...props} className={classNames("group/tooltip relative inline-grid", className, getSide(position))}>
      <span aria-describedby={tip ? id : undefined} style={{ display: "contents" }}>
        {children}
      </span>
      {tip ? (
        <span
          role="tooltip"
          id={id}
          {...tooltipProps}
          className={classNames(
            "absolute z-30 hidden w-40 max-w-max rounded-md bg-primary p-3 text-primary-foreground group-focus-within/tooltip:block group-hover/tooltip:block",
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
