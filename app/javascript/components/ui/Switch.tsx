import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type SwitchProps = Omit<React.HTMLProps<HTMLInputElement>, "type" | "role">;

/**
 * Toggle switch input component.
 *
 * Styled as a sliding toggle with a circular thumb.
 * Uses the native checkbox input with role="switch".
 *
 * Usage:
 * ```tsx
 * <Switch checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
 * ```
 */
export const Switch = React.forwardRef<HTMLInputElement, SwitchProps>(({ className, ...props }, ref) => (
  <input
    ref={ref}
    type="checkbox"
    role="switch"
    className={classNames(
      "relative h-[--big-icon-size] w-[calc(2*var(--big-icon-size)-0.375rem)] cursor-pointer appearance-none rounded-full border border-border bg-background transition-all duration-[--transition-duration] ease-out",
      "after:absolute after:top-[0.125rem] after:left-[0.1875rem] after:h-[calc(var(--big-icon-size)-0.375rem)] after:w-[calc(var(--big-icon-size)-0.375rem)] after:rounded-full after:bg-current after:transition-all after:duration-[--transition-duration] after:ease-out after:content-['']",
      "checked:bg-accent checked:after:left-[calc(100%-var(--big-icon-size)+0.1875rem)] checked:after:bg-accent-foreground",
      "disabled:cursor-not-allowed disabled:opacity-[--disabled-opacity]",
      className,
    )}
    {...props}
  />
));
Switch.displayName = "Switch";
