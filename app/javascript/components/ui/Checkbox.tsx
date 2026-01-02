import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type CheckboxProps = Omit<React.HTMLProps<HTMLInputElement>, "type">;

/**
 * Styled checkbox input component.
 *
 * Square checkbox with custom checkmark icon when checked.
 * Uses accent color background when checked.
 *
 * Usage:
 * ```tsx
 * <Checkbox checked={selected} onChange={(e) => setSelected(e.target.checked)} />
 * ```
 */
export const Checkbox = React.forwardRef<HTMLInputElement, CheckboxProps>(({ className, ...props }, ref) => (
  <input
    ref={ref}
    type="checkbox"
    className={classNames(
      "aspect-square h-[calc(1lh+0.125rem)] w-[calc(1lh+0.125rem)] shrink-0 cursor-pointer appearance-none rounded-lg border border-border bg-background text-base",
      "checked:border-accent checked:bg-accent checked:text-accent-foreground",
      "checked:after:mx-auto checked:after:block checked:after:min-h-[max(1lh,1em)] checked:after:w-[1em] checked:after:shrink-0 checked:after:bg-current checked:after:[mask-image:url('~images/icons/outline-check.svg')] checked:after:[mask-size:120%] checked:after:[mask-position:50%_50%] checked:after:[mask-repeat:no-repeat] checked:after:content-['']",
      "disabled:cursor-not-allowed disabled:opacity-[--disabled-opacity]",
      className,
    )}
    {...props}
  />
));
Checkbox.displayName = "Checkbox";
