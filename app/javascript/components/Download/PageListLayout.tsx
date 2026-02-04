import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const PageListLayout = ({
  pageList,
  children,
  className,
}: {
  pageList: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}) => (
  <div
    className={classNames(
      "flex min-h-0 flex-col gap-6 bg-background p-4 [scrollbar-gutter:stable] md:p-8 lg:flex-row lg:gap-16 lg:overflow-y-auto",
      className,
    )}
  >
    <div className="flex flex-col gap-4 [scrollbar-gutter:stable] lg:sticky lg:top-0 lg:h-full lg:max-h-[calc(100vh-184px)] lg:w-80 lg:overflow-y-auto lg:pb-8">
      {pageList}
    </div>
    <div className="h-0 flex-1">{children}</div>
  </div>
);

export const PageList = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div
      ref={ref}
      className={classNames("scoped-tailwind-preflight grid rounded-sm border bg-background", className)}
      role="tablist"
      {...props}
    />
  ),
);
PageList.displayName = "PageList";

export const PageListItem = ({
  className,
  asChild,
  isSelected,
  ...props
}: { className?: string; asChild?: boolean; isSelected?: boolean } & React.HTMLProps<HTMLDivElement>) => {
  const Component = asChild ? Slot : "div";
  return (
    <Component
      className={classNames(
        "flex items-center gap-2 p-4 not-first:border-t first:rounded-t-sm last:rounded-b-sm",
        isSelected && "bg-active-bg",
        className,
      )}
      aria-selected={isSelected}
      {...props}
    />
  );
};
