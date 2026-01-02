import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type ColorPickerProps = Omit<React.HTMLProps<HTMLInputElement>, "type">;

/**
 * Color picker input styled as a circular swatch.
 *
 * The color input is expanded to cover the container, creating a
 * clickable color swatch that opens the native color picker.
 *
 * Usage:
 * ```tsx
 * <ColorPicker value={color} onChange={(e) => setColor(e.target.value)} />
 * ```
 */
export const ColorPicker = React.forwardRef<HTMLInputElement, ColorPickerProps>(({ className, ...props }, ref) => (
  <div className={classNames("relative max-w-fit overflow-hidden rounded-full border border-border p-4", className)}>
    <input
      ref={ref}
      type="color"
      className="absolute -top-1/2 -left-1/2 h-[200%] w-[200%] max-w-none cursor-pointer border-none"
      {...props}
    />
  </div>
));
ColorPicker.displayName = "ColorPicker";
