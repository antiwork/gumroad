import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export type CheckboxProps = React.InputHTMLAttributes<HTMLInputElement>;

export const Checkbox = React.forwardRef<HTMLInputElement, CheckboxProps>(({ className, ...props }, ref) => (
  <div className="flex size-6 shrink-0 items-center justify-center">
    <input
      ref={ref}
      type="checkbox"
      className={classNames(
        "peer size-full cursor-pointer appearance-none rounded-lg border border-border checked:bg-accent",
        className,
      )}
      {...props}
    />
    <Icon name="outline-check" className="pointer-events-none absolute !hidden text-black peer-checked:!block" />
  </div>
));

Checkbox.displayName = "Checkbox";
