import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

const tabsVariants = cva("", {
  variants: {
    variant: {
      pills: "flex gap-3 overflow-x-auto",
      buttons: "tab-buttons",
    },
  },
  defaultVariants: {
    variant: "pills",
  },
});

const tabVariants = cva("", {
  variants: {
    variant: {
      pills: "shrink-0 rounded-full border border-transparent px-3 py-2 no-underline hover:border-border",
      buttons: "", // SCSS handles styling via [role="tab"]
    },
    active: {
      true: "",
      false: "",
    },
  },
  compoundVariants: [
    {
      variant: "pills",
      active: true,
      className: "border-border bg-background text-foreground",
    },
  ],
  defaultVariants: {
    variant: "pills",
    active: false,
  },
});

interface TabsProps extends React.HTMLProps<HTMLDivElement>, VariantProps<typeof tabsVariants> {
  children: React.ReactNode;
}

export const Tabs = ({ children, className, variant, ...props }: TabsProps) => (
  <div role="tablist" className={classNames(tabsVariants({ variant }), className)} {...props}>
    {children}
  </div>
);

interface TabProps extends Omit<React.HTMLProps<HTMLAnchorElement>, "selected">, VariantProps<typeof tabVariants> {
  children: React.ReactNode;
  asChild?: boolean;
  isSelected: boolean;
}

export const Tab = ({ children, isSelected, className, asChild, variant, ...props }: TabProps) => {
  const Component = asChild ? Slot : "a";

  return (
    <Component
      className={classNames(tabVariants({ variant, active: isSelected }), className)}
      role="tab"
      aria-selected={isSelected}
      {...props}
    >
      {children}
    </Component>
  );
};
