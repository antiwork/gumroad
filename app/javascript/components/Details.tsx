import { ChevronDown, ChevronRight } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type Props = {
  summary: React.ReactNode;
  summaryProps?: React.HTMLAttributes<HTMLElement>;
  open?: boolean;
  onToggle?: (open: boolean) => void;
  chevronPosition?: "left" | "right" | "none";
} & Omit<React.ComponentProps<"details">, "onToggle">;

export const Details = React.forwardRef<HTMLDetailsElement, Props>(
  ({ children, summary, open, onToggle, summaryProps, chevronPosition = "left", className, ...props }, ref) => {
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
            "flex cursor-pointer justify-between [&::-webkit-details-marker]:hidden [&::marker]:hidden",
            isOpen && "mb-2",
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
          {chevronPosition === "left" ? <Chevron className="mr-1 size-5 shrink-0" /> : null}
          {summary}
          {chevronPosition === "right" ? <Chevron className="col-start-2 ml-1 size-5 shrink-0" /> : null}
        </summary>
        {children}
      </details>
    );
  },
);
Details.displayName = "Details";
