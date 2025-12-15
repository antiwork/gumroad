import { Slot } from "@radix-ui/react-slot";
import { cva } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type PillColor = "primary" | "danger" | "success" | "warning" | undefined;
type PillSize = "default" | "small";

type PillProps = React.PropsWithChildren<{
  className?: string | undefined;
  asChild?: boolean;
  color?: PillColor;
  size?: PillSize;
}> &
  React.HTMLAttributes<HTMLElement>;

const pillVariants = cva(
  "inline-flex align-middle px-3 py-2 bg-background text-foreground border border-border truncate",
  {
    variants: {
      size: {
        default: "rounded-full",
        small: "rounded p-1 text-sm/4",
      },
      color: {
        primary: "bg-primary text-primary-foreground border-primary",
        danger: "bg-danger text-danger-foreground border-danger",
        success: "bg-success text-success-foreground border-success",
        warning: "bg-warning text-warning-foreground border-warning",
      },
    },
  },
);

export const Pill = React.forwardRef<HTMLDivElement, PillProps>(
  ({ className, asChild, color, size = "default", children, ...props }, ref) => {
    const Component = asChild ? Slot : "div";
    return (
      <Component ref={ref} className={classNames(pillVariants({ size, color }), className)} {...props}>
        {children}
      </Component>
    );
  },
);
Pill.displayName = "Pill";
