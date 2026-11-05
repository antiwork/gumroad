import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { enabledRadios, selectAdjacentRadio } from "$app/utils/radioGroupKeyboard";

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

    const isRadioGroup = role === "radiogroup";

    // A radiogroup is one tab stop: only the checked radio, or the first one when none is checked,
    // stays reachable with Tab. Re-applied on every render because the checked radio moves.
    React.useEffect(() => {
      const list = listRef.current;
      if (!isRadioGroup || !list) return;
      const enabled = enabledRadios(list);
      const tabStop = enabled.find((radio) => radio.getAttribute("aria-checked") === "true") ?? enabled[0];
      list.querySelectorAll<HTMLElement>('[role="radio"]').forEach((radio) => {
        radio.tabIndex = radio === tabStop ? 0 : -1;
      });
    });

    return (
      <TabVariantContext.Provider value={variant ?? "pills"}>
        <div
          role={role ?? "tablist"}
          onKeyDown={
            isRadioGroup
              ? (event: React.KeyboardEvent<HTMLDivElement>) => {
                  onKeyDown?.(event);
                  if (!event.defaultPrevented) selectAdjacentRadio(event);
                }
              : onKeyDown
          }
          className={classNames(tabsVariants({ variant }), className)}
          {...props}
          ref={listRef}
        >
          {children}
        </div>
      </TabVariantContext.Provider>
    );
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
