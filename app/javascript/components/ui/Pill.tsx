import { Slot } from "@radix-ui/react-slot";
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
const colorMap: Record<string, string> = {
  primary: "border bg-primary text-primary-foreground border-primary",
  danger: "border bg-danger text-danger-foreground border-danger",
  success: "border bg-success text-success-foreground border-success",
  warning: "border bg-warning text-warning-foreground border-warning",
};

export const Pill = React.forwardRef<HTMLDivElement, PillProps>(
  ({ className, asChild, color, size = "default", children, ...props }, ref) => {
    const baseClasses =
      "inline-flex align-middle px-3 py-2 bg-background text-foreground border border-border rounded-[10rem] truncate";
    const sizeClass = size === "small" ? "rounded p-1 text-sm" : "";
    const colorClasses = color ? (colorMap[color] ?? "") : "";
    const Component = asChild ? Slot : "div";

    return (
      <Component ref={ref} className={classNames(baseClasses, colorClasses, sizeClass, className)} {...props}>
        {children}
      </Component>
    );
  },
);

Pill.displayName = "Pill";

export default Pill;
