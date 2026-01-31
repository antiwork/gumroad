import * as React from "react";

import { classNames } from "$app/utils/classNames";

// after: overrides should be removed after complete forms migration
const switchBaseStyles =
  "cursor-pointer appearance-none h-5 min-h-5 w-[2.125rem] min-w-[2.125rem] border border-border rounded-full bg-background relative transition-all duration-150 checked:bg-accent disabled:cursor-not-allowed disabled:opacity-30 after:content-['']! after:absolute! after:top-[0.125rem]! after:left-[0.1875rem]! after:size-[0.875rem]! after:rounded-lg! after:bg-foreground! after:transition-all after:duration-150 checked:after:left-[calc(100%-1.0625rem)]! checked:after:bg-accent-foreground!";

export const Switch = React.forwardRef<
  HTMLInputElement,
  { label?: React.ReactNode } & Omit<React.InputHTMLAttributes<HTMLInputElement>, "type" | "role">
>(({ className, label, disabled, ...props }, ref) => (
  <label className={classNames("inline-flex cursor-pointer gap-2", disabled && "cursor-not-allowed opacity-30")}>
    <input
      ref={ref}
      type="checkbox"
      role="switch"
      disabled={disabled}
      className={classNames(switchBaseStyles, className)}
      {...props}
    />
    {label ? <span>{label}</span> : null}
  </label>
));
Switch.displayName = "Switch";
