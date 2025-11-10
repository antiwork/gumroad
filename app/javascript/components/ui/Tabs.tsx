import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

const tabsVariants = cva("", {
  variants: {
    variant: {
      pills: "flex gap-3 overflow-x-auto",
      buttons: "grid gap-3 md:auto-cols-fr md:grid-flow-col",
    },
  },
  defaultVariants: {
    variant: "pills",
  },
});

const tabVariants = cva("", {
  variants: {
    variant: {
      pills: "shrink-0 rounded-full border-transparent px-3 py-2 hover:border-border",
      buttons:
        "flex items-start gap-3 rounded-sm border-border px-4 py-3 text-left transition-all not-active:hover:-translate-1 not-active:hover:shadow",
    },
    active: {
      true: "bg-background",
      false: "",
    },
  },
  compoundVariants: [
    {
      variant: "pills",
      active: true,
      className: "border-border text-foreground",
    },
    {
      variant: "buttons",
      active: true,
      className: "shadow -translate-1",
    },
  ],
  defaultVariants: {
    variant: "pills",
    active: false,
  },
});

const TabVariantContext = React.createContext<"pills" | "buttons">("pills");

interface TabsProps extends React.HTMLProps<HTMLDivElement>, VariantProps<typeof tabsVariants> {
  children: React.ReactNode;
}

export const Tabs = React.forwardRef<HTMLDivElement, TabsProps>(({ children, className, variant, ...props }, ref) => (
  <div role="tablist" className={classNames(tabsVariants({ variant }), className)} {...props} ref={ref}>
    <TabVariantContext.Provider value={variant ?? "pills"}> {children} </TabVariantContext.Provider>
  </div>
));
Tabs.displayName = "Tabs";

export const TabIcon = ({ name }: { name: IconName }) => (
  <div className="flex-shrink-0 text-xl">
    <Icon name={name} />
  </div>
);

interface TabProps extends Omit<React.HTMLProps<HTMLAnchorElement>, "selected"> {
  children: React.ReactNode;
  asChild?: boolean;
  isSelected: boolean;
}

export const Tab = ({ children, isSelected, className, asChild, ...props }: TabProps) => {
  const variant = React.useContext(TabVariantContext);
  const Component = asChild ? Slot : "a";

  return (
    <Component
      className={classNames("border no-underline", tabVariants({ variant, active: isSelected }), className)}
      role="tab"
      aria-selected={isSelected}
      {...props}
    >
      {children}
    </Component>
  );
};
