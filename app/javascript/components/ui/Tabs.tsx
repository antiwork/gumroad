import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";
import { createPortal } from "react-dom";

import { classNames } from "$app/utils/classNames";
import { selectAdjacentRadio, useRadioGroupTabStop } from "$app/utils/radioGroupKeyboard";

import { TextTabsContext, useIsBelowWide } from "$app/components/HeaderNavContext";
import { usePageSlots } from "$app/components/PageSlots";

// Wide screens only: a phone keeps the pills, which are easier to tap. The negative margins cancel
// the page header's padding, so the selected tab's bar sits on the header's bottom border.
// Important throughout: these override the pill's own classes, which come later in the stylesheet.
const textTabsClasses = {
  row: "lg:-my-2! lg:gap-6!",
  stacked: "lg:-mb-8! lg:gap-6!",
  // In the phone's menu: a list, like the destinations under it.
  menu: "flex-col! gap-0! overflow-visible!",
};
const wideTextTab =
  "lg:rounded-none! lg:border-0! lg:bg-transparent! lg:px-0! lg:hover:shadow-[inset_0_-0.125rem_0_var(--color-border)]";
const textTabClasses = {
  row: classNames(wideTextTab, "lg:py-5!"),
  stacked: classNames(wideTextTab, "lg:pt-0! lg:pb-4!"),
  menu: "rounded-none! border-0! bg-transparent! px-6! py-4! text-inherit! hover:text-accent",
};
const selectedTextTabClasses = {
  row: "lg:font-bold lg:shadow-[inset_0_-0.125rem_0_currentColor]!",
  stacked: "lg:font-bold lg:shadow-[inset_0_-0.125rem_0_currentColor]!",
  // Bold and a bar as well as the accent, so the state does not rest on colour alone.
  menu: "font-bold text-accent! shadow-[inset_0.25rem_0_0_var(--color-accent)]",
};

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
      // A Button inside the tab sets the halo to the store's offset, but this lift wins while hovered.
      buttons:
        "flex items-start gap-3 rounded-sm border-border px-4 py-3 text-left transition-all not-active:hover:-translate-1 not-active:hover:shadow lift-halo not-active:hover:[--lift-halo-offset:var(--spacing)]",
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
      // The important modifier is required: Tab wraps Button via asChild, so both class strings are
      // joined and Button's `border-border` can otherwise win the CSS-order fight.
      className: "border-indicator! ring-1 ring-indicator",
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

export const Tabs = React.forwardRef<HTMLDivElement, TabsProps>(
  ({ children, className, variant, role, onKeyDown, ...props }, ref) => {
    const listRef = React.useRef<HTMLDivElement>(null);
    React.useImperativeHandle<HTMLDivElement | null, HTMLDivElement | null>(ref, () => listRef.current);

    // A pill row scrolls sideways on narrow screens, so a selected tab past the edge would load hidden.
    // Align again once web fonts load, because they widen the labels after the first layout.
    React.useEffect(() => {
      const align = () => {
        const list = listRef.current;
        const selected = list?.querySelector<HTMLElement>('[role="tab"][aria-selected="true"]');
        if (!list || !selected) return;
        const listRect = list.getBoundingClientRect();
        const tabRect = selected.getBoundingClientRect();
        if (tabRect.right > listRect.right) list.scrollLeft += Math.ceil(tabRect.right - listRect.right);
        else if (tabRect.left < listRect.left) list.scrollLeft -= Math.ceil(listRect.left - tabRect.left);
      };
      align();
      if ("fonts" in document) void document.fonts.ready.then(align);
    }, []);

    const textTabsContext = React.useContext(TextTabsContext);
    const { navTabs } = usePageSlots();
    const isBelowWide = useIsBelowWide();
    const inPageHeader = (variant ?? "pills") === "pills" ? textTabsContext : null;
    // A phone has no room for a row of tabs under the bar, so they join the menu.
    const textTabs = inPageHeader && isBelowWide && navTabs ? "menu" : inPageHeader;
    const isRadioGroup = role === "radiogroup";
    useRadioGroupTabStop(listRef, isRadioGroup);

    const tabs = (
      <TabVariantContext.Provider value={variant ?? "pills"}>
        <div
          role={role ?? "tablist"}
          onKeyDown={
            isRadioGroup
              ? (event: React.KeyboardEvent<HTMLDivElement>) => {
                  onKeyDown?.(event);
                  selectAdjacentRadio(event);
                }
              : onKeyDown
          }
          className={classNames(tabsVariants({ variant }), textTabs && textTabsClasses[textTabs], className)}
          {...props}
          ref={listRef}
        >
          {children}
        </div>
      </TabVariantContext.Provider>
    );
    return textTabs === "menu" && navTabs
      ? createPortal(<TextTabsContext.Provider value="menu">{tabs}</TextTabsContext.Provider>, navTabs)
      : tabs;
  },
);
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
  const textTabsContext = React.useContext(TextTabsContext);
  const textTab = variant === "pills" ? textTabsContext : null;
  const Component = asChild ? Slot : "a";

  return (
    <Component
      className={classNames(
        "border no-underline",
        tabVariants({ variant, active: isSelected }),
        textTab && textTabClasses[textTab],
        textTab && isSelected && selectedTextTabClasses[textTab],
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
