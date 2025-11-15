import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type Position = "top" | "left" | "bottom" | "right";

const centerClasses = (position: Position) => ({
  "left-1/2 -translate-x-1/2": position === "top" || position === "bottom",
  "top-1/2 -translate-y-1/2": position === "left" || position === "right",
});

type Props = {
  children: React.ReactNode;
  tip: React.ReactNode | null;
  position?: Position | undefined;
  tooltipProps?: React.HTMLAttributes<HTMLSpanElement> | undefined;
} & React.HTMLAttributes<HTMLSpanElement>;
export const WithTooltip = ({ tip, children, position = "bottom", className, tooltipProps, ...props }: Props) => {
  const id = React.useId();

  if (tip == null) return children;

  return (
    <span {...props} className={classNames("group/tooltip relative inline-grid", className, position)}>
      <span aria-describedby={id} style={{ display: "contents" }}>
        {children}
      </span>
      {tip ? (
        <span
          role="tooltip"
          id={id}
          {...tooltipProps}
          className={classNames(
            "absolute z-30 hidden w-40 max-w-max rounded-md bg-primary p-3 text-primary-foreground group-focus-within/tooltip:block group-hover/tooltip:block",
            centerClasses(position),
            {
              "bottom-full -translate-y-2": position === "top",
              "right-full -translate-x-2": position === "left",
              "top-full translate-y-2": position === "bottom",
              "left-full translate-x-2": position === "right",
            },
            tooltipProps?.className,
          )}
        >
          <div
            className={classNames("absolute border-6 border-transparent", centerClasses(position), {
              "top-full border-t-primary": position === "top",
              "left-full border-l-primary": position === "left",
              "bottom-full border-b-primary": position === "bottom",
              "right-full border-r-primary": position === "right",
            })}
          ></div>
          {tip}
        </span>
      ) : null}
    </span>
  );
};
