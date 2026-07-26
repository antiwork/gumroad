import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { stateBorderStyles, useFieldset } from "$app/components/ui/Fieldset";

const InputGroupContext = React.createContext<{ isInsideInputGroup: boolean; disabled?: boolean }>({
  isInsideInputGroup: false,
});

export const useInputGroup = () => React.useContext(InputGroupContext);

const inputGroupVariants = cva(
  [
    "inline-flex items-center w-full gap-2 relative py-0 px-4 min-h-12 border border-border rounded bg-background text-foreground focus-within:outline-2 focus-within:outline-accent focus-within:outline-offset-0",
    "[&>.icon]:text-muted",
  ],
  {
    variants: {
      disabled: {
        // Don't fade the whole group with `opacity`: CSS opacity applies to the entire subtree,
        // so a disabled group that exists purely to display a value (a percentage discount's
        // fixed-amount field, a published workflow's price, the card field while a payment is
        // processing) renders that value at 30% opacity, which sellers read as an empty field.
        // Signal "not editable" with a tinted background and the cursor instead, so the value
        // itself stays at full contrast.
        //
        // The background tint is a translucent overlay, and Windows High Contrast mode (and any
        // other forced-colours mode) replaces author background colours with a system colour, so
        // the tint disappears there and a disabled group would look identical to an editable one.
        // A dashed border survives forced colours, so the state stays visible without relying on
        // colour alone.
        true: "cursor-not-allowed bg-active-bg forced-colors:border-dashed",
        false: "",
      },
      readOnly: {
        true: "bg-inherit border-none px-0",
        false: "",
      },
    },
    defaultVariants: {
      disabled: false,
      readOnly: false,
    },
  },
);

export const InputGroup = React.forwardRef<
  HTMLDivElement,
  React.HTMLAttributes<HTMLDivElement> & VariantProps<typeof inputGroupVariants>
>(({ className, disabled, readOnly, children, ...props }, ref) => {
  const { state } = useFieldset();
  // Recompute when `disabled` changes — several groups toggle it from form state (for example
  // the collaborator form enabling a percentage field), and memoizing on anything else leaves
  // descendants reading a stale disabled flag.
  const contextValue = React.useMemo(() => ({ isInsideInputGroup: true, disabled: disabled ?? false }), [disabled]);

  return (
    <InputGroupContext.Provider value={contextValue}>
      <div
        ref={ref}
        className={classNames(inputGroupVariants({ disabled, readOnly }), stateBorderStyles[state], className)}
        {...props}
      >
        {children}
      </div>
    </InputGroupContext.Provider>
  );
});
InputGroup.displayName = "InputGroup";
