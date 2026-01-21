import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { useFieldset, stateBorderStyles } from "$app/components/ui/Fieldset";

const selectBaseStyles =
  "font-[inherit] text-base leading-[1.4] px-4 py-3 border border-border rounded block w-full bg-background placeholder:text-muted focus:outline-2 focus:outline-offset-0 focus:outline-accent disabled:cursor-not-allowed disabled:opacity-30 appearance-none bg-no-repeat pr-10";

export const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, style, children, ...props }, ref) => {
    const { state } = useFieldset();

    return (
      <select
        ref={ref}
        className={classNames(selectBaseStyles, stateBorderStyles[state], className)}
        style={{
          backgroundImage: `linear-gradient(45deg, transparent 50%, currentColor 50%, var(--color-background) calc(50% + 2px)),
          linear-gradient(315deg, transparent 50%, currentColor 50%, var(--color-background) calc(50% + 2px))`,
          backgroundPosition: "calc(100% - 1rem - 0.5em) center, calc(100% - 1rem) center",
          backgroundSize: "0.5em 0.5em",
          ...style,
        }}
        {...props}
      >
        {children}
      </select>
    );
  },
);
Select.displayName = "Select";
