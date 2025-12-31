import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type InputProps = React.InputHTMLAttributes<HTMLInputElement>;

export const Input = React.forwardRef<HTMLInputElement, InputProps>(({ className, ...props }, ref) => (
  <div className={classNames("bg-filled flex h-12 items-center gap-2 rounded border border-border px-4 focus-within:ring-2 focus-within:ring-accent focus-within:outline-none", className)}>
    <input
      ref={ref}
      className="flex-1 bg-transparent font-[inherit] text-base outline-none"
      {...props}
    />
  </div>
));

Input.displayName = "Input";
