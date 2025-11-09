import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const TabButtons = ({ children, className, ...props }: React.HTMLProps<HTMLDivElement>) => (
  <div role="tablist" className={classNames("grid gap-3 md:auto-cols-fr md:grid-flow-col", className)} {...props}>
    {children}
  </div>
);

export const TabButtonIcon = ({ name }: { name: IconName }) => (
  <div className="flex-shrink-0 text-xl">
    <Icon name={name} />
  </div>
);

export const TabButton = ({
  children,
  isSelected,
  className,
  asChild,
  ...props
}: React.HTMLProps<HTMLButtonElement> & {
  isSelected: boolean;
  children: React.ReactNode;
  asChild?: boolean;
}) => {
  const Component = asChild ? Slot : "button";
  return (
    <Component
      className={classNames(
        "flex items-start gap-3 rounded-sm border border-border px-4 py-3 text-left no-underline transition-all hover:-translate-1 hover:shadow",
        isSelected ? "-translate-1 shadow" : "",
        className,
      )}
      role="tab"
      aria-selected={isSelected}
      {...props}
      type="button"
    >
      {children}
    </Component>
  );
};
