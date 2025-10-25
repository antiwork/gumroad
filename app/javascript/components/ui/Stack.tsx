import * as React from "react";

import { classNames } from "$app/utils/classNames";

type StackProps = React.PropsWithChildren<{
  className?: string | undefined;
  as?: "div" | "section" | "main" | "aside";
  borderless?: boolean;
}> &React.HTMLAttributes<HTMLElement>;

type StackItemProps = React.PropsWithChildren<{
  className?: string | undefined;
  as?: "div" | "header" | "footer"| "details"| "h3" | "h4" | "h5" | "h6"| "section"| "fieldset"| "p"| "button"| "span";
}> & React.HTMLAttributes<HTMLElement>;


export const Stack = React.forwardRef<HTMLElement, StackProps>(
  ({ className, as: Component = "div", borderless = false, children, ...rest }, ref) => {

    const baseClasses="grid bg-background border border-border rounded stack-component";

    const mainStackClasses = Component === "main" ? "h-min my-4 mx-auto max-w-md w-[calc(100%-2*1rem)] [&>*]:flex-col [&>*]:items-stretch" : "";


    const borderlessClasses = borderless ? "border-none gap-4 [&>*]:p-0 [&>*]:border-none" : "";

    return (
      <Component
        ref={ref as any}
        className={classNames(
          baseClasses,
          mainStackClasses,
          borderlessClasses,
          className
        )}
        {...rest}
      >
        {children}
      </Component>
    );
  }
);

export const StackItem = React.forwardRef<HTMLElement, StackItemProps>(
  ({ className, as: Component = "div",children, ...rest }, ref) => {
    const baseClasses = "flex flex-wrap items-center p-4 gap-4 justify-between not-first:border-t not-first:border-border";

    const detailsClasses = Component === "details" ? "block" : "";

    return (
      <Component
        ref={ref as any}
        className={classNames(
          baseClasses,
          detailsClasses,
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
StackItem.displayName = "StackItem";
