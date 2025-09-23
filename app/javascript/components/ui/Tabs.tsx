import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Tabs = ({
  children,
  className,
  ...props
}: { children: React.ReactNode } & React.HTMLProps<HTMLDivElement>) => (
  <div role="tablist" className={classNames("flex gap-3 overflow-x-auto", className)} {...props}>
    {children}
  </div>
);

export const Tab = ({
  children,
  isSelected,
  className,
  asChild,
  ...props
}: { children: React.ReactNode; asChild?: boolean; isSelected: boolean } & React.HTMLProps<HTMLAnchorElement>) => {
  const Component = asChild ? Slot : "a";

  return (
    <Component
      className={classNames(
        "shrink-0 rounded-full border border-transparent px-3 py-2 no-underline hover:border-border",
        isSelected && "border-border bg-background text-foreground",
        className,
      )}
      role="tab"
      aria-selected={isSelected}
      {...props}
    >
      {children}
    </Component>
  );
};
