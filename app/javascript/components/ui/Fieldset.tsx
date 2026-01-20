import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

const fieldsetVariants = cva("flex flex-col border-none gap-2 [&[role=group]_label_input]:ml-auto", {
  variants: {
    state: {
      default: "",
      success: "[&_input]:border-success [&_select]:border-success [&_small]:text-success",
      danger: "[&_input]:border-danger [&_select]:border-danger [&_small]:text-danger",
      warning: "[&_input]:border-warning [&_select]:border-warning [&_small]:text-warning",
      info: "[&_input]:border-info [&_select]:border-info [&_small]:text-info",
    },
  },
  defaultVariants: {
    state: "default",
  },
});

export const Fieldset = React.forwardRef<
  HTMLFieldSetElement,
  React.FieldsetHTMLAttributes<HTMLFieldSetElement> & VariantProps<typeof fieldsetVariants>
>(({ className, state, children, ...props }, ref) => (
  <fieldset ref={ref} className={classNames(fieldsetVariants({ state }), className)} {...props}>
    {children}
  </fieldset>
));
Fieldset.displayName = "Fieldset";

export const FieldsetTitle = React.forwardRef<
  HTMLLegendElement,
  { children: React.ReactNode } & React.HTMLAttributes<HTMLLegendElement>
>(({ className, children, ...props }, ref) => (
  <legend
    ref={ref}
    className={classNames(
      "relative mb-2 flex w-full items-center justify-between text-base leading-[1.4] font-bold",
      "[&_a,&_label]:font-normal",
      className,
    )}
    {...props}
  >
    {children}
  </legend>
));
FieldsetTitle.displayName = "FieldsetTitle";
