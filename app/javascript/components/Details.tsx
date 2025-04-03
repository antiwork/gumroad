import * as React from "react";

type Props = {
  summary: React.ReactNode;
  summaryProps?: React.HTMLAttributes<HTMLElement>;
  open?: boolean;
  onToggle?: (open: boolean) => void;
} & Omit<React.ComponentProps<"details">, "onToggle">;

export const Details = React.forwardRef<HTMLDetailsElement, Props>(
  ({ children, summary, open, onToggle, summaryProps, ...props }, ref) => (
    <details open={open} ref={ref} {...props}>
      <summary
        {...summaryProps}
        onClick={(e) => {
          if (!onToggle) return;
          e.preventDefault();
          e.stopPropagation();
          onToggle(!open);
        }}
      >
        {summary}
      </summary>
      {children}
    </details>
  ),
);
Details.displayName = "Details";
