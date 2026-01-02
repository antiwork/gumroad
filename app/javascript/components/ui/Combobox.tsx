import * as React from "react";

import { classNames } from "$app/utils/classNames";

export type ComboboxProps = React.HTMLProps<HTMLDivElement>;

/**
 * Styled container for combobox/dropdown components.
 *
 * Provides styling for:
 * - Container positioning
 * - Input border radius when expanded
 * - Datalist dropdown panel
 * - Option items with focus states
 * - Multi-select checkmarks
 *
 * Usage:
 * ```tsx
 * <Combobox>
 *   <Input role="combobox" aria-expanded={open}>...</Input>
 *   <datalist>
 *     <div role="option">Option 1</div>
 *   </datalist>
 * </Combobox>
 * ```
 */
export const Combobox = React.forwardRef<HTMLDivElement, ComboboxProps>(({ className, children, ...props }, ref) => (
  <div
    ref={ref}
    className={classNames(
      "relative",
      "[&_input[aria-expanded='true']]:rounded-b-none",
      "[&_.input:has(input[aria-expanded='true'])]:rounded-b-none",
      "[&_datalist]:absolute [&_datalist]:top-full [&_datalist]:left-0 [&_datalist]:z-[20] [&_datalist]:block [&_datalist]:w-full [&_datalist]:overflow-auto [&_datalist]:rounded-b [&_datalist]:border [&_datalist]:border-border [&_datalist]:bg-background [&_datalist]:py-2 [&_datalist]:shadow",
      "[&_datalist_option]:flex [&_datalist_option]:cursor-pointer [&_datalist_option]:items-center [&_datalist_option]:px-4 [&_datalist_option]:py-2",
      "[&_datalist_[role='option']]:flex [&_datalist_[role='option']]:cursor-pointer [&_datalist_[role='option']]:items-center [&_datalist_[role='option']]:px-4 [&_datalist_[role='option']]:py-2",
      "[&_datalist_.option]:flex [&_datalist_.option]:cursor-pointer [&_datalist_.option]:items-center [&_datalist_.option]:px-4 [&_datalist_.option]:py-2",
      "[&_datalist_option.focused]:bg-primary [&_datalist_option.focused]:text-primary-foreground",
      "[&_datalist_option:focus]:bg-primary [&_datalist_option:focus]:text-primary-foreground",
      "[&_datalist_[role='option'].focused]:bg-primary [&_datalist_[role='option'].focused]:text-primary-foreground",
      "[&_datalist_[role='option']:focus]:bg-primary [&_datalist_[role='option']:focus]:text-primary-foreground",
      "[&_datalist_.option.focused]:bg-primary [&_datalist_.option.focused]:text-primary-foreground",
      "[&_datalist_option_img]:h-12 [&_datalist_option_img]:shrink-0 [&_datalist_option_img]:basis-12 [&_datalist_option_img]:rounded [&_datalist_option_img]:border [&_datalist_option_img]:border-border [&_datalist_option_img]:object-cover",
      "[&_datalist_[role='option']_img]:h-12 [&_datalist_[role='option']_img]:shrink-0 [&_datalist_[role='option']_img]:basis-12 [&_datalist_[role='option']_img]:rounded [&_datalist_[role='option']_img]:border [&_datalist_[role='option']_img]:border-border [&_datalist_[role='option']_img]:object-cover",
      "[&_datalist_h3]:px-4 [&_datalist_h3]:py-2",
      "[&_datalist_h3:not(:first-child)]:mt-2 [&_datalist_h3:not(:first-child)]:border-t [&_datalist_h3:not(:first-child)]:border-border [&_datalist_h3:not(:first-child)]:pt-4",
      className,
    )}
    {...props}
  >
    {children}
  </div>
));
Combobox.displayName = "Combobox";
