import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type BaseProps = {
  children: React.ReactNode;
  className?: string;
} & React.HTMLAttributes<HTMLElement>;

export const CartItemList = ({ children, className, ...props }: BaseProps) => (
  <div
    role="list"
    className={classNames("overflow-hidden rounded-sm border border-border bg-background", className)}
    {...props}
  >
    {children}
  </div>
);

export const CartItem = ({
  className,
  children,
  extra,
  asChild = false,
  ...props
}: BaseProps & { asChild?: boolean; extra?: React.ReactNode }) => {
  const Comp = asChild ? Slot : "div";
  return (
    <Comp role="listitem" className={classNames("border-border not-first:border-t", className)} {...props}>
      <>
        <section className="col-span-3 flex flex-row gap-4 rounded-sm p-4 not-first:rounded-none sm:p-0 sm:pr-4">
          {children}
        </section>
        {extra ? <section className="flex flex-col gap-4 border-border p-4 not-first:border-t">{extra}</section> : null}
      </>
    </Comp>
  );
};

export const CartItemMedia = ({ className, children, ...props }: BaseProps) => (
  <figure
    className={classNames(
      "h-fit w-14 rounded-sm border border-foreground sm:h-full sm:w-36 sm:rounded-none sm:border-y-0 sm:border-l-0",
      className,
    )}
    {...props}
  >
    {children}
  </figure>
);

export const CartItemMain = ({ className, children, ...props }: BaseProps) => (
  <section className={classNames("flex flex-1 flex-col gap-1 sm:py-4", className)} {...props}>
    {children}
  </section>
);

export const CartItemTitle = ({
  className,
  children,
  asChild = false,
  ...props
}: BaseProps & { asChild?: boolean }) => {
  const Comp = asChild ? Slot : "h4";
  return (
    <Comp className={classNames("line-clamp-2 font-bold", className)} {...props}>
      {children}
    </Comp>
  );
};

export const CartItemFooter = ({ className, children, ...props }: BaseProps) => (
  <footer className={classNames("mt-auto items-end", className)} {...props}>
    <ul className="flex list-none flex-col gap-x-4 gap-y-1 pl-0 sm:flex-row sm:flex-wrap">{children}</ul>
  </footer>
);

export const CartItemFooterItem = ({ className, children, ...props }: BaseProps) => (
  <li className={className} {...props}>
    {children}
  </li>
);

export const CartItemEnd = ({ className, children, ...props }: BaseProps) => (
  <section className={classNames("ml-auto flex flex-col items-end gap-1 sm:py-4", className)} {...props}>
    {children}
  </section>
);
