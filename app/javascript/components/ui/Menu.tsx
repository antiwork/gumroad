import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

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

const menuItemClasses =
  "flex items-center gap-2 cursor-pointer overflow-hidden border-0 px-4 py-2 text-ellipsis whitespace-nowrap hover:bg-active-bg";

export const MenuItem = React.forwardRef<
  HTMLDivElement,
  React.HTMLAttributes<HTMLElement> & {
    variant?: "danger";
    asChild?: boolean;
  }
>(({ className, variant, asChild, ...rest }, ref) => {
  const Component = asChild ? Slot : "div";
  return (
    <Component
      ref={ref}
      role="menuitem"
      className={classNames(menuItemClasses, variant === "danger" && "text-danger", className)}
      {...rest}
    />
  );
});
MenuItem.displayName = "MenuItem";

export const MenuItemRadio = React.forwardRef<
  HTMLDivElement,
  React.HTMLAttributes<HTMLDivElement> & {
    checked?: boolean;
    asChild?: boolean;
  }
>(({ className, checked, asChild, ...rest }, ref) => {
  const Component = asChild ? Slot : "div";
  return (
    <Component
      ref={ref}
      role="menuitemradio"
      aria-checked={checked}
      className={classNames(menuItemClasses, checked && "font-bold", className)}
      {...rest}
    />
  );
});
MenuItemRadio.displayName = "MenuItemRadio";
