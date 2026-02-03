import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Label = React.forwardRef<
  HTMLLabelElement,
  { children: React.ReactNode } & React.LabelHTMLAttributes<HTMLLabelElement>
>(({ className, children, ...props }, ref) => (
  <label
    ref={ref}
    className={classNames(
      "inline-flex cursor-pointer gap-2 font-normal has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-30",
      className,
    )}
    {...props}
  >
    {children}
  </label>
));
Label.displayName = "Label";
