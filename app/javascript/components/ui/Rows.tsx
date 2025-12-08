import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Rows = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div className={classNames("rounded-sm border border-border bg-background", className)} {...props} ref={ref} />
  ),
);
Rows.displayName = "Rows";

export const Row = ({
  className,
  asChild,
  ...props
}: { className?: string; asChild?: boolean } & React.HTMLProps<HTMLDivElement>) => {
  const Component = asChild ? Slot : "div";
  return (
    <Component
      className={classNames(
        "grid items-center gap-4 border-border p-4 not-last:border-b sm:grid-cols-[minmax(30%,1fr)_auto]",
        className,
      )}
      {...props}
    />
  );
};

export const RowContent = ({
  className,
  asChild,
  ...props
}: React.HTMLProps<HTMLDivElement> & { asChild?: boolean }) => {
  const Component = asChild ? Slot : "div";
  return <Component className={classNames("flex items-center gap-2", className)} {...props} />;
};

export const RowActions = ({ className, ...props }: React.HTMLProps<HTMLDivElement>) => (
  <div className={classNames("flex flex-wrap items-center justify-end gap-2", className)} {...props} />
);

export const RowDetails = ({
  className,
  asChild,
  ...props
}: { asChild?: boolean } & React.HTMLProps<HTMLDivElement>) => {
  const Component = asChild ? Slot : "div";
  return <Component className={classNames("col-span-full", className)} {...props} />;
};

export const RowDragHandle = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div ref={ref} className={classNames("order-first -ml-4 text-muted", className)} {...props}>
      <Icon name="outline-drag" />
    </div>
  ),
);
RowDragHandle.displayName = "RowDragHandle";
