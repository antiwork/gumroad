import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Rows = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div className={classNames("rounded-sm border border-border bg-background", className)} {...props} ref={ref} />
  ),
);
Rows.displayName = "Rows";

const RowContext = React.createContext<{ isExpanded?: boolean | undefined }>({});
const useRowContext = () =>
  assertDefined(React.useContext(RowContext), "useRowContext must be used within a RowContextProvider");

export const Row = ({
  className,
  asChild,
  isExpanded,
  ...props
}: { className?: string; asChild?: boolean; isExpanded?: boolean } & React.HTMLProps<HTMLDivElement>) => {
  const Component = asChild ? Slot : "div";
  const contextValue = React.useMemo(() => ({ isExpanded }), [isExpanded]);
  return (
    <RowContext.Provider value={contextValue}>
      <Component
        aria-expanded={isExpanded}
        className={classNames(
          "grid items-center gap-4 border-border p-4 not-last:border-b sm:grid-cols-[minmax(30%,1fr)_auto]",
          className,
        )}
        {...props}
      />
    </RowContext.Provider>
  );
};

export const RowContent = ({ className, ...props }: React.HTMLProps<HTMLDivElement>) => {
  const { isExpanded } = useRowContext();
  return (
    <div
      className={classNames("flex items-center gap-2", { "cursor-pointer": isExpanded !== undefined }, className)}
      {...props}
    />
  );
};

export const RowActions = ({ className, ...props }: React.HTMLProps<HTMLDivElement>) => (
  <div className={classNames("flex flex-wrap items-center justify-end gap-2", className)} {...props} />
);

export const RowDetails = ({
  className,
  asChild,
  ...props
}: { asChild?: boolean } & React.HTMLProps<HTMLDivElement>) => {
  const { isExpanded } = useRowContext();
  const Component = asChild ? Slot : "div";
  return <Component className={classNames("col-span-full", className, { hidden: isExpanded === false })} {...props} />;
};

export const RowDragHandle = ({ className, ...props }: React.HTMLProps<HTMLDivElement>) => (
  <div className={classNames("order-first -ml-4 text-muted", className)} {...props}>
    <Icon name="outline-drag" />
  </div>
);

export const RowExpandIndicator = (props: React.HTMLProps<HTMLSpanElement>) => {
  const { isExpanded } = useRowContext();
  return <Icon {...props} name={isExpanded ? "outline-cheveron-down" : "outline-cheveron-right"} />;
};
