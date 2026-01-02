import * as React from "react";

import { classNames } from "$app/utils/classNames";

export interface RadioButtonGroupProps extends React.HTMLProps<HTMLDivElement> {
  role?: "radiogroup";
}

/**
 * Container for radio button groups with responsive grid layout.
 *
 * Children should be buttons with role="radio" and aria-checked attributes.
 * The grid defaults to auto-fit columns with min 15rem width.
 *
 * Override grid columns using Tailwind classes:
 * - `grid-cols-2` for fixed 2 columns
 * - `grid-cols-1 sm:grid-cols-2 md:grid-cols-3` for responsive
 */
export const RadioButtonGroup = React.forwardRef<HTMLDivElement, RadioButtonGroupProps>(
  ({ className, children, role = "radiogroup", ...props }, ref) => (
    <div
      ref={ref}
      role={role}
      className={classNames(
        "grid grid-cols-[repeat(auto-fit,minmax(min(15rem,100%),1fr))] gap-4",
        "[&>button]:items-start [&>button]:justify-start [&>button]:gap-3 [&>button]:text-left",
        "[&>button>:first-child]:shrink-0",
        "[&>button.vertical]:flex-col",
        "[&>button_h4]:font-bold",
        "[&>button[aria-checked='true']]:-translate-x-1 [&>button[aria-checked='true']]:-translate-y-1 [&>button[aria-checked='true']]:bg-active-bg [&>button[aria-checked='true']]:shadow",
        className,
      )}
      {...props}
    >
      {children}
    </div>
  ),
);
RadioButtonGroup.displayName = "RadioButtonGroup";
