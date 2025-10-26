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
      "@container flex h-full flex-col gap-x-6 gap-y-16 overflow-y-auto bg-background p-4 [scrollbar-gutter:stable] md:p-8 lg:grid lg:grid-cols-[20rem_1fr]",
      className,
    )}
  >
    <div className="flex flex-col gap-4 lg:sticky lg:top-0 lg:overflow-y-auto lg:pr-2 lg:pb-8 lg:@max-[100vh]:max-h-[100cqh]">
      {pageList}
    </div>
    {children}
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
        "tailwind-override flex items-center gap-2 p-4 text-left not-first:border-t first:rounded-t-sm last:rounded-b-sm",
        isSelected && "bg-muted",
        className,
      )}
      aria-selected={isSelected}
      {...props}
    />
  );
};
