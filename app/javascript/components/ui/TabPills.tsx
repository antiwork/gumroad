import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const TabPills = ({ children, className, ...props }: React.HTMLProps<HTMLDivElement>) => (
  <div role="tablist" className={classNames("flex gap-3 overflow-x-auto", className)} {...props}>
    {children}
  </div>
);

interface TabProps extends Omit<React.HTMLProps<HTMLAnchorElement>, "selected"> {
  children: React.ReactNode;
  asChild?: boolean;
  isSelected: boolean;
}

export const TabPill = ({ children, isSelected, className, asChild, ...props }: TabProps) => {
  const Component = asChild ? Slot : "a";

  return (
    <Component
      className={classNames(
        "shrink-0 rounded-full border border-transparent px-3 py-2 no-underline hover:border-border",
        isSelected ? "border-border bg-background" : "",
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
