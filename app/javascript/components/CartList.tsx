import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type BaseProps = {
  className?: string;
  children?: React.ReactNode;
} & React.HTMLAttributes<HTMLElement>;

export const CartList = ({ children, className }: BaseProps) => (
  <div
    role="list"
    className={classNames(
      "overflow-hidden rounded-sm border border-border bg-background *:not-first:border-t *:not-first:border-border",
      className,
    )}
  >
    {children}
  </div>
);

export const CartListItem = ({ className, children, ...props }: BaseProps) => (
  <div role="listitem" className={classNames("grid border-border not-first:border-t", className)} {...props}>
    {children}
  </div>
);

export const CartItemRow = ({ className, children }: BaseProps) => (
  <section
    className={classNames(
      "col-span-3 grid grid-cols-[3.625rem_1fr_auto] gap-x-4 rounded-sm p-4 not-first:rounded-none sm:grid-cols-[8.5rem_1fr_auto] sm:p-0 sm:pr-4",
      className,
    )}
  >
    {children}
  </section>
);

export const CartItemMedia = ({ className, children }: BaseProps) => (
  <figure
    className={classNames(
      "h-fit rounded-sm border border-foreground sm:h-full sm:rounded-none sm:border-y-0 sm:border-l-0 sm:border-foreground",
      className,
    )}
  >
    {children}
  </figure>
);

export const CartItemMain = ({ className, children }: BaseProps) => (
  <section className={classNames("flex flex-col gap-1 sm:py-4", className)}>{children}</section>
);

export const CartItemTitle = ({ className, children, asChild = false }: BaseProps & { asChild?: boolean }) => {
  const Comp = asChild ? Slot : "h4";
  return <Comp className={classNames("line-clamp-2 font-bold", className)}>{children}</Comp>;
};

export const CartItemFooter = ({ className, children }: BaseProps) => (
  <footer className={classNames("mt-auto items-end", className)}>{children}</footer>
);

export const CartItemEnd = ({ className, children }: BaseProps) => (
  <section className={classNames("flex flex-col items-end gap-1 sm:py-4", className)}>{children}</section>
);

export const CartItemExtra = ({ className, children }: BaseProps) => (
  <section className={classNames("col-span-3 grid gap-4 border-border p-4 not-first:border-t", className)}>
    {children}
  </section>
);
