import { ChevronDown, ChevronRight } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type Props = {
  summary: React.ReactNode;
  summaryProps?: React.HTMLAttributes<HTMLElement>;
  open?: boolean;
  onToggle?: (open: boolean) => void;
  toggle?: boolean;
  chevronPosition?: "left" | "right";
} & Omit<React.ComponentProps<"details">, "onToggle">;

export const Details = React.forwardRef<HTMLDetailsElement, Props>(
  ({ children, summary, open, onToggle, summaryProps, toggle, chevronPosition = "left", className, ...props }, ref) => {
    const [internalOpen, setInternalOpen] = React.useState(open ?? false);
    const isOpen = onToggle ? (open ?? false) : internalOpen;

    const Chevron = isOpen ? ChevronDown : ChevronRight;

    return (
      <details
        open={open}
        ref={ref}
        className={className}
        onToggle={
          onToggle
            ? undefined
            : (e) => {
                setInternalOpen((e.target as HTMLDetailsElement).open);
              }
        }
        {...props}
      >
        <summary
          {...summaryProps}
          className={classNames(
            "[all:inherit] [outline:revert] grid cursor-pointer [list-style:none] [&::marker]:hidden [&::-webkit-details-marker]:hidden",
            toggle ? "grid-cols-[1fr]" : chevronPosition === "right" ? "grid-cols-[1fr_auto]" : "grid-cols-[auto_1fr]",
            isOpen && !toggle ? "mb-2" : "",
            summaryProps?.className,
          )}
          onClick={(e) => {
            summaryProps?.onClick?.(e);
            if (!onToggle) return;
            e.preventDefault();
            e.stopPropagation();
            onToggle(!open);
          }}
        >
          {!toggle && chevronPosition === "left" ? (
            <Chevron className="shrink-0 mr-1 size-[1em] min-h-[max(1lh,1em)]" />
          ) : null}
          {summary}
          {!toggle && chevronPosition === "right" ? (
            <Chevron className="shrink-0 ml-1 size-[1em] min-h-[max(1lh,1em)] col-start-2" />
          ) : null}
        </summary>
        {children}
      </details>
    );
  },
);
Details.displayName = "Details";
