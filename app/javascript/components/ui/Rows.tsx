import { Slot } from "@radix-ui/react-slot";
import classNames from "classnames";
import * as React from "react";

import { Icon } from "$app/components/Icons";

type DivProps = React.ComponentPropsWithoutRef<"div">;

export const Rows = React.forwardRef<HTMLDivElement, DivProps>(({ className, ...props }, ref) => (
  <div
    ref={ref}
    className={classNames("rounded-sm border border-border bg-background text-foreground", className)}
    {...props}
  />
));
Rows.displayName = "Rows";

export const Row = React.forwardRef<HTMLDivElement, DivProps & { asChild?: boolean }>(
  ({ children, className, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "div";
    const showIcon = props["aria-expanded"] !== undefined;
    const isExpanded = props["aria-expanded"] === true || props["aria-expanded"] === "true";

    return (
      <Comp
        ref={ref}
        className={classNames(
          "flex flex-wrap items-center gap-4 border-border p-4 not-last:border-b",
          { "cursor-pointer": showIcon },
          className,
        )}
        {...props}
      >
        {showIcon ? (
          <Icon name={isExpanded ? "outline-cheveron-down" : "outline-cheveron-right"} className="-mr-2" />
        ) : null}
        {children}
      </Comp>
    );
  },
);
Row.displayName = "Row";

export const RowContent = React.forwardRef<HTMLDivElement, DivProps>(({ className, ...props }, ref) => (
  <div ref={ref} className={classNames("flex min-w-0 flex-1 items-center gap-2", className)} {...props} />
));
RowContent.displayName = "RowContent";

export const RowActions = React.forwardRef<HTMLDivElement, DivProps>(({ className, ...props }, ref) => (
  <div
    ref={ref}
    className={classNames("ml-auto flex flex-wrap items-center justify-end gap-2", className)}
    {...props}
  />
));
RowActions.displayName = "RowActions";
