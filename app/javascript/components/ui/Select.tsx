import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { useFieldset, stateBorderStyles } from "$app/components/ui/Fieldset";
import { Icon } from "$app/components/Icons";
import { baseStyles } from "$app/components/ui/Input";

export const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, children, ...props }, ref) => {
    const { state } = useFieldset();

    return (
      <div className="relative inline-grid">
        <select
          ref={ref}
          className={classNames(baseStyles, "appearance-none pr-10", stateBorderStyles[state], className)}
          {...props}
        >
          {children}
        </select>
        <Icon
          name="outline-cheveron-down"
          className="pointer-events-none absolute top-1/2 right-4 -translate-y-1/2 text-muted"
        />
      </div>
    );
  },
);
Select.displayName = "Select";
