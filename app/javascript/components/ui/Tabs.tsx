import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

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
      // The selected card gets an accent-colored outline (border + 1px ring, so ~2px total
      // without any layout shift). The outline replaces the old lift + drop shadow, which
      // was too subtle on some seller themes for buyers to tell which tier/version they
      // picked — and the dark shadow clashed with bright accent colors anyway.
      // `border-accent!` needs the important modifier because when Tab wraps a Button via
      // asChild, both components' class strings are joined and Button's own `border-border`
      // can otherwise win the CSS-order fight. `accent` is a seller theme token, so this
      // follows each storefront's configured accent color in light and dark mode.
      className: "border-accent! ring-1 ring-accent",
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
  <TabVariantContext.Provider value={variant ?? "pills"}>
    <div role="tablist" className={classNames(tabsVariants({ variant }), className)} {...props} ref={ref}>
      {children}
    </div>
  </TabVariantContext.Provider>
));
Tabs.displayName = "Tabs";

export const TabIcon = ({ children }: { children: React.ReactNode }) => (
  <div className="flex shrink-0 items-center text-xl">{children}</div>
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
