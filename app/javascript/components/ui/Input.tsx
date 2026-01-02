import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

const inputVariants = cva(
  "inline-flex items-center gap-2 relative min-h-[--form-element-height] w-full text-base rounded border border-border bg-background px-4 focus-within:outline focus-within:outline-[0.125rem] focus-within:outline-accent [&>input]:border-none [&>input]:flex-1 [&>input]:bg-transparent [&>input]:shadow-none [&>input]:outline-none [&>input]:-mx-4 [&>input]:px-4 [&>textarea]:border-none [&>textarea]:flex-1 [&>textarea]:bg-transparent [&>textarea]:shadow-none [&>textarea]:outline-none [&>textarea]:-mx-4 [&>textarea]:px-4 [&>select]:border-none [&>select]:flex-1 [&>select]:bg-transparent [&>select]:shadow-none [&>select]:outline-none [&>select]:-mx-4 [&>select]:px-4 [&>.icon]:text-muted [&>.fake-input]:flex-1",
  {
    variants: {
      disabled: {
        true: "cursor-not-allowed opacity-[--disabled-opacity]",
      },
      readOnly: {
        true: "bg-body",
      },
    },
  },
);

export interface InputProps
  extends Omit<React.HTMLProps<HTMLDivElement>, "disabled" | "readOnly">,
    VariantProps<typeof inputVariants> {
  asChild?: boolean;
}

export const Input = React.forwardRef<HTMLDivElement, InputProps>(
  ({ className, asChild, disabled, readOnly, children, ...props }, ref) => {
    const Component = asChild ? Slot : "div";
    return (
      <Component ref={ref} className={classNames(inputVariants({ disabled, readOnly }), className)} {...props}>
        {children}
      </Component>
    );
  },
);
Input.displayName = "Input";
