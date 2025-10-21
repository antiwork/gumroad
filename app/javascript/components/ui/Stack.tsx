import * as React from "react";

import { classNames } from "$app/utils/classNames";

type StackProps = React.PropsWithChildren<{
  className?: string;
  as?: "div" | "section" | "main" | "aside";
  borderless?: boolean;
  twoColumns?: boolean;
}> &React.HTMLAttributes<HTMLElement>;

export const Stack = React.forwardRef<HTMLElement, StackProps>(
  ({ className, as: Component = "div", borderless = false, twoColumns = false, children, ...rest }, ref) => {
    // Base stack styling - matches the visual appearance of .stack
    const baseClasses = "grid bg-background border border-border rounded stack-component [&>*]:flex [&>*]:items-center [&>*]:p-4 [&>*]:gap-4 [&>*]:justify-between [&>*:not(:first-child)]:border-t [&>*:not(:first-child)]:border-border [&>*>:first-child]:flex-grow [&>*>:first-child:where(.button,fieldset)]:flex-[0_1_0%] [&>*>:where(.button,fieldset)+:where(.button,fieldset)]:flex-1 [&>*_h4]:font-bold [&>*_h5]:font-bold [&>*_h6]:font-bold [&>details]:block [&>details_summary]:grid [&>details_summary]:grid-flow-col [&>details_summary]:grid-cols-[1fr_auto] [&>details_summary::before]:col-start-2";

    // Main stack styling - matches main.stack visual appearance
    const mainStackClasses = Component === "main" ? "h-min m-4 mx-auto max-w-[28rem] w-[calc(100%-2*1rem)] [&>header]:text-center [&>footer]:text-center [&>*]:flex-col [&>*]:items-start" : "";

    // Borderless variant - removes borders and padding, adds gap
    const borderlessClasses = borderless ? "!border-0 gap-4 [&>*]:p-0 [&>*]:!border-0" : "";

    // Two columns variant - creates 2-column grid on large screens
    const twoColumnsClasses = twoColumns ? "lg:grid-cols-2 lg:[&>:nth-child(odd)]:border-r lg:[&>:nth-child(odd)]:border-r-border lg:[&>:nth-child(2)]:!border-t-0" : "";

    return (
      <Component
        ref={ref as any}
        className={classNames(
          baseClasses,
          mainStackClasses,
          borderlessClasses,
          twoColumnsClasses,
          className
        )}
        {...rest}
      >
        {children}
      </Component>
    );
  }
);

Stack.displayName = "Stack";
