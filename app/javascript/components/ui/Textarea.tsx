import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { baseInputStyles } from "$app/components/ui/Input";

export const Textarea = React.forwardRef<HTMLTextAreaElement, React.TextareaHTMLAttributes<HTMLTextAreaElement>>(
  ({ className, readOnly, ...props }, ref) => (
    <textarea
      ref={ref}
      readOnly={readOnly}
      className={classNames(
        baseInputStyles,
        "resize-y",
        readOnly && "cursor-default bg-body focus:outline-none",
        className,
      )}
      {...props}
    />
  ),
);
Textarea.displayName = "Textarea";
