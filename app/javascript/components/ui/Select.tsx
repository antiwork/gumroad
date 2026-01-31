import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { useFieldset, stateBorderStyles } from "$app/components/ui/Fieldset";
import { Icon } from "$app/components/Icons";
import { baseInputStyles } from "$app/components/ui/Input";

export const Select = React.forwardRef<
  HTMLSelectElement,
  { wrapperClassName?: string } & React.SelectHTMLAttributes<HTMLSelectElement>
>(({ className, wrapperClassName, children, ...props }, ref) => {
  const { state } = useFieldset();

  return (
    <div className={classNames("relative inline-grid", wrapperClassName)}>
      <select
        ref={ref}
        className={classNames(baseInputStyles, "appearance-none pr-10", stateBorderStyles[state], className)}
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
});
Select.displayName = "Select";
