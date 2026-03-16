import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

const menuItemStyles =
  "block cursor-pointer overflow-hidden border-0 px-4 py-2 text-ellipsis whitespace-nowrap hover:bg-active-bg [&>:not(:last-child)]:mr-2";

export const Menu = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, ...rest }, ref) => (
    <div
      ref={ref}
      role="menu"
      className={classNames("rounded border border-border bg-background py-2 text-foreground shadow", className)}
      {...rest}
    />
  ),
);
Menu.displayName = "Menu";

type MenuItemProps = React.HTMLAttributes<HTMLElement> & {
  variant?: "danger";
  asChild?: boolean;
};

export const MenuItem = React.forwardRef<HTMLDivElement, MenuItemProps>(
  ({ className, variant, asChild, ...rest }, ref) => {
    const Component = asChild ? Slot : "div";
    return (
      <Component
        ref={ref}
        role="menuitem"
        className={classNames(menuItemStyles, variant === "danger" && "text-danger", className)}
        {...rest}
      />
    );
  },
);
MenuItem.displayName = "MenuItem";

type MenuItemRadioProps = React.HTMLAttributes<HTMLDivElement> & {
  checked?: boolean;
  asChild?: boolean;
};

export const MenuItemRadio = React.forwardRef<HTMLDivElement, MenuItemRadioProps>(
  ({ className, checked, asChild, ...rest }, ref) => {
    const Component = asChild ? Slot : "div";
    return (
      <Component
        ref={ref}
        role="menuitemradio"
        aria-checked={checked}
        className={classNames(menuItemStyles, checked && "font-bold", className)}
        {...rest}
      />
    );
  },
);
MenuItemRadio.displayName = "MenuItemRadio";
