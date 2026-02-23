import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Checkbox = React.forwardRef<
  HTMLInputElement,
  { wrapperClassName?: string } & Omit<React.InputHTMLAttributes<HTMLInputElement>, "type">
>(({ className, wrapperClassName, ...props }, ref) => (
  <span className={classNames("relative inline-flex shrink-0 items-center justify-center", wrapperClassName)}>
    <input
      ref={ref}
      type="checkbox"
      className={classNames(
        "appearance-none",
        "size-[calc(1lh+0.125rem)]",
        "border border-border",
        "bg-background",
        "text-base leading-snug",
        "shrink-0 cursor-pointer",
        "disabled:cursor-not-allowed disabled:opacity-30",
        "checked:bg-accent",
        "rounded-lg",
        "peer",
        "after:hidden!", // this should be removed after complete forms migration
        className,
      )}
      {...props}
    />
    <Icon
      name="outline-check"
      className="pointer-events-none absolute hidden! text-accent-foreground peer-checked:block!"
    />
  </span>
));
Checkbox.displayName = "Checkbox";
