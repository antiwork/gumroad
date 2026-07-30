import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { useFieldset, stateBorderStyles } from "$app/components/ui/Fieldset";
import { useInputGroup } from "$app/components/ui/InputGroup";

export const baseInputStyles = classNames(
  "font-[inherit] py-3 px-4 text-base leading-snug text-foreground",
  "border border-border rounded block w-full bg-background placeholder:text-muted",
  "focus:outline-2 focus:outline-indicator focus:outline-offset-0",
  "disabled:cursor-not-allowed disabled:opacity-30",
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
          // Inside a disabled InputGroup the group itself signals the disabled state (tinted
          // background, not-allowed cursor), so the input must not fade its own text on top of
          // that: a faded value in a group that exists to DISPLAY a value reads as an empty
          // field, which is what made the PWYW "Minimum amount" mirror look unset to sellers.
          inputGroupDisabled && "disabled:opacity-100",
          className,
        )}
        {...props}
      />
    );
  },
);
Input.displayName = "Input";
