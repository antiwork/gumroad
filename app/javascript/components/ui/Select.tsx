import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { useFieldset, stateBorderStyles } from "$app/components/ui/Fieldset";
import { Icon } from "$app/components/Icons";

const selectBaseStyles =
  "font-[inherit] text-base leading-[1.4] px-4 py-3 border border-border rounded block w-full bg-background placeholder:text-muted focus:outline-2 focus:outline-offset-0 focus:outline-accent disabled:cursor-not-allowed disabled:opacity-30 appearance-none pr-10";

export const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, children, ...props }, ref) => {
    const { state } = useFieldset();

    return (
      <div className="relative inline-grid">
        <select ref={ref} className={classNames(selectBaseStyles, stateBorderStyles[state], className)} {...props}>
          {children}
        </select>
        <Icon name="outline-cheveron-down" className="pointer-events-none absolute top-1/2 right-4 -translate-y-1/2" />
      </div>
    );
  },
);
Select.displayName = "Select";
