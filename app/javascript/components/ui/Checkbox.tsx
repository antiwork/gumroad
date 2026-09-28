import { Check } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { stateBorderStyles, useFieldset } from "$app/components/ui/Fieldset";

export const Checkbox = React.forwardRef<
  HTMLInputElement,
  { wrapperClassName?: string } & Omit<React.InputHTMLAttributes<HTMLInputElement>, "type">
>(({ className, wrapperClassName, ...props }, ref) => {
  const { state } = useFieldset();
  return (
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
          "checked:bg-accent-with-text",
          // Follows the seller's --radius down to square, but never rounder than the stock 0.5rem.
          "rounded-[min(var(--radius-lg),calc(var(--radius)*2))]",
          "peer",
          stateBorderStyles[state],
          className,
        )}
        {...props}
      />
      <Check className="pointer-events-none absolute hidden size-5 text-accent-foreground peer-checked:block" />
    </span>
  );
});
Checkbox.displayName = "Checkbox";
