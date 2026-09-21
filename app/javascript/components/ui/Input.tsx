import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { useFieldset, stateBorderStyles } from "$app/components/ui/Fieldset";
import { useInputGroup } from "$app/components/ui/InputGroup";

export const baseInputStyles = classNames(
  "font-[inherit] py-3 px-4 text-base leading-snug text-foreground",
  "border border-border rounded block w-full bg-background placeholder:text-muted",
  "focus:outline-2 focus:outline-indicator focus:outline-offset-0",
  "opacity-100 disabled:cursor-not-allowed disabled:bg-active-bg forced-colors:disabled:border-dashed",
);

const inputGroupChildStyles = "border-none flex-1 bg-transparent shadow-none outline-none -mx-4 max-w-none";

export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, readOnly, ...props }, ref) => {
    const { isInsideInputGroup, disabled: inputGroupDisabled } = useInputGroup();
    const { state } = useFieldset();

    return (
      <input
        ref={ref}
        readOnly={readOnly}
        className={classNames(
          baseInputStyles,
          readOnly && "cursor-default bg-body focus:outline-none",
          isInsideInputGroup ? inputGroupChildStyles : stateBorderStyles[state],
          // The disabled group owns the background and border, so its input must not add either again.
          inputGroupDisabled && "disabled:bg-transparent forced-colors:disabled:border-none",
          className,
        )}
        {...props}
      />
    );
  },
);
Input.displayName = "Input";
