import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { stateBorderStyles, useFieldset } from "$app/components/ui/Fieldset";
import { baseInputStyles } from "$app/components/ui/Input";

export type SelectProps = { wrapperClassName?: string } & React.SelectHTMLAttributes<HTMLSelectElement>;

export const Select = React.forwardRef<HTMLSelectElement, SelectProps>(
  ({ className, wrapperClassName, children, ...props }, ref) => {
    const { state } = useFieldset();

    return (
      <div className={classNames("relative inline-grid", wrapperClassName)}>
        <select
          ref={ref}
          className={classNames(
            baseInputStyles,
            // The chevron sits at `right-4` and is 20px wide, so the value needs 44px of right
            // padding to clear it — otherwise a long value (a country name at 375px) runs into the
            // icon. `truncate` keeps the overflow readable as an ellipsis instead of a hard cut.
            "appearance-none truncate bg-none pr-11",
            stateBorderStyles[state],
            className,
          )}
          {...props}
        >
          {children}
        </select>
        <ChevronDown className="pointer-events-none absolute top-1/2 right-4 size-5 -translate-y-1/2 text-muted" />
      </div>
    );
  },
);
Select.displayName = "Select";
