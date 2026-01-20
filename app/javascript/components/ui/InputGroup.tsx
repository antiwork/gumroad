import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

const InputGroupContext = React.createContext<{ isInsideInputGroup: boolean; disabled?: boolean }>({
  isInsideInputGroup: false,
});

export const useInputGroup = () => React.useContext(InputGroupContext);

const inputGroupVariants = cva(
  [
    "inline-flex items-center w-full gap-2 relative py-0 px-4 min-h-[3.025rem] border border-border rounded bg-background text-foreground focus-within:outline-2 focus-within:outline-accent focus-within:outline-offset-0",
    "[&>.icon]:text-muted",
  ],
  {
    variants: {
      disabled: {
        true: "cursor-not-allowed opacity-30",
        false: "",
      },
      readOnly: {
        true: "bg-body",
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
>(({ className, disabled, readOnly, children, ...props }, ref) => (
  <InputGroupContext.Provider value={{ isInsideInputGroup: true, disabled: disabled ?? false }}>
    <div ref={ref} className={classNames(inputGroupVariants({ disabled, readOnly }), className)} {...props}>
      {children}
    </div>
  </InputGroupContext.Provider>
));
InputGroup.displayName = "InputGroup";
