import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

const CartItemContext = React.createContext<{ isBundleItem: boolean } | null>(null);
const useCartItemContext = () => assertDefined(React.useContext(CartItemContext));

type BaseProps = {
  children: React.ReactNode;
  className?: string;
} & React.HTMLAttributes<HTMLElement>;

export const CartItemList = ({ children, className, ...props }: BaseProps) => (
  <div role="list" className={classNames("rounded-sm border border-border bg-background", className)} {...props}>
    {children}
  </div>
);

export const CartItem = ({
  className,
  children,
  extra,
  asChild = false,
  isBundleItem = false,
  ...props
}: BaseProps & { asChild?: boolean; extra?: React.ReactNode; isBundleItem?: boolean }) => {
  const Comp = asChild ? Slot : "div";
  const paddingClasses = isBundleItem ? "p-0" : "p-4 sm:p-5";
  const rowGapClasses = isBundleItem ? "gap-0" : "gap-4 sm:gap-5";
  const contextValue = React.useMemo(() => ({ isBundleItem }), [isBundleItem]);

  return (
    <CartItemContext.Provider value={contextValue}>
      <Comp
        role="listitem"
        className={classNames("border-border not-first:border-t", className, isBundleItem && "group/bundle")}
        {...props}
      >
        <>
          <section className={classNames("flex flex-row", rowGapClasses, paddingClasses)}>{children}</section>
          {extra ? (
            <section className="flex flex-col gap-4 border-border p-4 pt-0 sm:p-6 sm:pt-0">{extra}</section>
          ) : null}
        </>
      </Comp>
    </CartItemContext.Provider>
  );
};

export const CartItemMedia = ({ className, children, ...props }: BaseProps) => {
  const { isBundleItem } = useCartItemContext();
  const bundleClasses = isBundleItem
    ? "rounded-none border-none group-first/bundle:rounded-tl group-last/bundle:rounded-bl"
    : "";

  return (
    <figure
      className={classNames(
        "tailwind-override h-fit w-14 overflow-hidden rounded-sm border border-border bg-(image:--product-cover-placeholder) bg-cover bg-center dark:bg-(image:--product-cover-placeholder-dark)",
        bundleClasses,
        className,
      )}
      {...props}
    >
      {children}
    </figure>
  );
};

export const CartItemQuantity = ({ className, children, ...props }: BaseProps & { label?: string }) => (
  <div
    className={classNames(
      "absolute top-0 right-0 flex h-5 min-w-5 translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border border-primary-foreground bg-primary px-1 text-xs font-normal text-primary-foreground sm:h-6 sm:min-w-6 sm:px-1.5",
      className,
    )}
    {...props}
  >
    <span className="sr-only">Qty: {children}</span>
    {children}
  </div>
);

export const CartItemMain = ({ className, children, ...props }: BaseProps) => {
  const { isBundleItem } = useCartItemContext();
  const bundleClasses = isBundleItem ? "justify-center self-stretch border-l border-border p-4" : "";

  return (
    <section className={classNames("flex flex-1 flex-col gap-1", bundleClasses, className)} {...props}>
      {children}
    </section>
  );
};

export const CartItemTitle = ({
  className,
  children,
  asChild = false,
  ...props
}: BaseProps & { asChild?: boolean }) => {
  const Comp = asChild ? Slot : "h4";
  return (
    <Comp className={classNames("line-clamp-2 text-base font-medium no-underline sm:text-lg", className)} {...props}>
      {children}
    </Comp>
  );
};

export const CartItemFooter = ({ className, children, ...props }: BaseProps) => (
  <footer className={classNames("mt-auto flex flex-col gap-x-4 gap-y-1 text-sm sm:flex-wrap", className)} {...props}>
    {children}
  </footer>
);

export const CartItemActions = ({ className, children, ...props }: BaseProps) => (
  <div className={classNames("flex flex-wrap items-stretch gap-3 pt-2", className)} {...props}>
    {children}
  </div>
);

export const CartItemEnd = ({ className, children, ...props }: BaseProps) => (
  <section className={classNames("ml-auto flex flex-col items-end gap-1", className)} {...props}>
    {children}
  </section>
);
