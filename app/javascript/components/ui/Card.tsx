import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type CardProps = React.PropsWithChildren<{
  className?: string | undefined;
  asChild?: boolean;
  borderless?: boolean;
}> &
  React.HTMLAttributes<HTMLElement>;

export const Card = React.forwardRef<HTMLDivElement, CardProps>(
  ({ className, asChild, borderless = false, children, ...rest }, ref) => {
    const Component = asChild ? Slot : "div";
    return (
      <Component
        ref={ref}
        className={classNames(
          "grid divide-y divide-solid divide-border rounded border border-border bg-background",
          borderless && "gap-4 border-none [&>*]:border-none [&>*]:p-0",
          className,
        )}
        {...rest}
      >
        {children}
      </Component>
    );
  },
);

Card.displayName = "Card";

type CardContentProps = React.PropsWithChildren<{
  className?: string | undefined;
  asChild?: boolean;
  details?: boolean;
}> &
  React.HTMLAttributes<HTMLElement>;

export const CardContent = React.forwardRef<HTMLDivElement, CardContentProps>(
  ({ className, asChild, details, children, ...rest }, ref) => {
    const Component = asChild ? Slot : "div";
    return (
      <Component
        ref={ref}
        className={classNames("flex flex-wrap items-center justify-between gap-4 p-4", details && "block", className)}
        {...rest}
      >
        {children}
      </Component>
    );
  },
);

CardContent.displayName = "CardContent";
