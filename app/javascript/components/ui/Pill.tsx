import * as React from "react";
import {Slot} from "@radix-ui/react-slot";

import { classNames } from "$app/utils/classNames";

type PillColor = "primary" | "danger" | "success" | "warning" |undefined;
type PillKind = "dismissable" | "selectable";
type PillSize = "default" | "small";

type PillProps = React.PropsWithChildren<{
  className?: string | undefined;
  asChild?: boolean;
  color?: PillColor;
  size?: PillSize;
  kind?: PillKind;
}> & React.HTMLAttributes<HTMLElement>;
const colorMap: Record<string, string> = {
  primary:  "border bg-primary text-primary-foreground border-primary",
  danger:   "border bg-danger text-danger-foreground border-danger",
  success:  "border bg-success text-success-foreground border-success",
  warning:  "border bg-warning text-warning-foreground border-warning",
};

export const Pill = React.forwardRef<HTMLElement, PillProps>(
  (
    { className, asChild, color, size = "default", kind, children, ...props },
    ref
  ) => {
    const baseClasses = "inline-block align-middle px-3 py-2 bg-background text-foreground border border-border rounded-[10rem] truncate";
    const sizeClass = size === "small" ? "rounded p-1 text-sm" : "";
    const colorClasses = color ? colorMap[color] ?? "" : "";
    const kindClasses = kind === "dismissable" ? "cursor-pointer": kind==="selectable"?"relative cursor-pointer":"";
    const Component = asChild ? Slot : "div";
    const wrappedChildren = asChild && typeof children === 'string'
      ? <span>{children}</span>
      : children;

    return (
      <Component
        ref={ref as any}
        className={classNames(baseClasses,colorClasses, sizeClass,kindClasses, className)}
        {...props}
      >
        {wrappedChildren}
      </Component>
    );
  }
);

Pill.displayName = "Pill";

export default Pill;


