import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const ColorPicker = React.forwardRef<
  HTMLInputElement,
  Omit<React.InputHTMLAttributes<HTMLInputElement>, "type">
>(({ className, ...props }, ref) => (
  <div className="relative max-w-fit overflow-hidden rounded-full border border-control p-4 has-focus-visible:outline-2 has-focus-visible:outline-offset-2 has-focus-visible:outline-indicator">
    <input
      ref={ref}
      type="color"
      className={classNames(
        "absolute -top-1/2 -left-1/2 h-[200%] w-[200%] max-w-none cursor-pointer border-none",
        className,
      )}
      {...props}
    />
  </div>
));
ColorPicker.displayName = "ColorPicker";
