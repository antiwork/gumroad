import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type RadioProps = Omit<React.HTMLProps<HTMLInputElement>, "type">;

/**
 * Styled radio input component.
 *
 * Circular radio button with inner dot when checked.
 * Uses accent color background when checked.
 *
 * Usage:
 * ```tsx
 * <Radio name="option" value="a" checked={value === "a"} onChange={() => setValue("a")} />
 * ```
 */
export const Radio = React.forwardRef<HTMLInputElement, RadioProps>(({ className, ...props }, ref) => (
  <input
    ref={ref}
    type="radio"
    className={classNames(
      "aspect-square h-[calc(1lh+0.125rem)] w-[calc(1lh+0.125rem)] shrink-0 cursor-pointer appearance-none rounded-full border border-border bg-background text-base",
      "checked:border-accent checked:bg-accent checked:p-[0.375rem]",
      "checked:after:block checked:after:h-full checked:after:rounded-full checked:after:bg-current checked:after:content-['']",
      "disabled:cursor-not-allowed disabled:opacity-[--disabled-opacity]",
      className,
    )}
    {...props}
  />
));
Radio.displayName = "Radio";
