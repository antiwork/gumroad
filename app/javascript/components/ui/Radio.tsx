import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Radio = React.forwardRef<
  HTMLInputElement,
  { wrapperClassName?: string } & Omit<React.InputHTMLAttributes<HTMLInputElement>, "type">
>(({ className, wrapperClassName, ...props }, ref) => (
  <span className={classNames("relative inline-flex shrink-0 items-center justify-center", wrapperClassName)}>
    <input
      ref={ref}
      type="radio"
      className={classNames(
        "appearance-none",
        "size-[calc(1lh+0.125rem)]",
        "border border-border",
        "bg-background",
        "text-base leading-snug",
        "shrink-0 cursor-pointer",
        "disabled:cursor-not-allowed disabled:opacity-30",
        "checked:bg-accent",
        "rounded-full",
        "peer",
        "after:hidden!", // this should be removed after complete forms migration
        className,
      )}
      {...props}
    />
    <span className="pointer-events-none absolute hidden! size-[0.65rem] rounded-full bg-accent-foreground peer-checked:block!" />
  </span>
));
Radio.displayName = "Radio";
