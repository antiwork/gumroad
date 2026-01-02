import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

const fieldsetVariants = cva(
  "flex flex-col gap-2 border-none [&>legend]:mb-2 [&>legend]:flex [&>legend]:w-full [&>legend]:items-center [&>legend]:text-base [&>legend]:font-bold [&>legend>:last-child:not(:only-child)]:ml-auto [&>legend_a]:font-normal [&>legend_label]:font-normal [&>small]:text-muted [&[role='group']_label]:w-full [&[role='group']_label_input]:ml-auto",
  {
    variants: {
      state: {
        success:
          "[&_input]:border-success [&_select]:border-success [&_textarea]:border-success [&>small]:text-success",
        danger: "[&_input]:border-danger [&_select]:border-danger [&_textarea]:border-danger [&>small]:text-danger",
        warning:
          "[&_input]:border-warning [&_select]:border-warning [&_textarea]:border-warning [&>small]:text-warning",
        info: "[&_input]:border-info [&_select]:border-info [&_textarea]:border-info [&>small]:text-info",
      },
    },
  },
);

export interface FieldsetProps extends React.HTMLProps<HTMLFieldSetElement>, VariantProps<typeof fieldsetVariants> {}

/**
 * Styled fieldset component with state variants.
 *
 * Provides flex column layout with legend and small element styling.
 * State variants (success, danger, warning, info) color the input borders
 * and small text.
 *
 * Usage:
 * ```tsx
 * <Fieldset state="danger">
 *   <legend>Email</legend>
 *   <Input><input type="email" /></Input>
 *   <small>Please enter a valid email</small>
 * </Fieldset>
 * ```
 */
export const Fieldset = React.forwardRef<HTMLFieldSetElement, FieldsetProps>(
  ({ className, state, children, ...props }, ref) => (
    <fieldset ref={ref} className={classNames(fieldsetVariants({ state }), className)} {...props}>
      {children}
    </fieldset>
  ),
);
Fieldset.displayName = "Fieldset";
