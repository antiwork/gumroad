import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { formatPriceCentsWithoutCurrencySymbol, formatUSDCentsWithExpandedCurrencySymbol } from "$app/utils/currency";

export function CartList({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <div
      role="list"
      className={classNames(
        "overflow-hidden rounded-sm border border-border bg-background *:border-border *:not-first:border-t",
        className,
      )}
    >
      {children}
    </div>
  );
}

export function CartListItem({
  media,
  title,
  body,
  footer,
  end,
  children,
  className,
  endClassName,
}: {
  media: React.ReactNode;
  title: React.ReactNode;
  body?: React.ReactNode;
  footer?: React.ReactNode;
  end?: React.ReactNode;
  children?: React.ReactNode;
  className?: string;
  endClassName?: string;
}) {
  return (
    <div role="listitem" className={classNames("override grid border-border not-first:border-t", className)}>
      <section className="col-span-3 grid grid-cols-[3.625rem_1fr_auto] gap-x-4 rounded-sm p-4 **:list-none not-first:rounded-none sm:grid-cols-[8.5rem_1fr_auto] sm:p-0 sm:pr-4">
        <figure className="rounded-sm border border-foreground sm:h-full sm:rounded-none sm:border-y-0 sm:border-l-0 sm:border-foreground">
          {media}
        </figure>
        <section className="flex flex-col gap-1 last:items-end sm:py-4">
          <div className="line-clamp-2 **:font-bold">{title}</div>
          {body}
          {footer ? <footer className="mt-auto items-end *:pl-0">{footer}</footer> : null}
        </section>
        <section className={classNames("flex flex-col items-end gap-1 sm:py-4", endClassName)}>{end}</section>
      </section>
      {children ? (
        <section className="override col-span-3 grid gap-4 border-t border-border p-4">{children}</section>
      ) : null}
    </div>
  );
}

export function CartPriceItem({
  title,
  price,
  useExpandedCurrencySymbol = false,
  className,
}: {
  title: React.ReactNode;
  price?: number | null;
  useExpandedCurrencySymbol?: boolean;
  className?: string;
}) {
  if (!price || price === 0) {
    return null;
  }

  return (
    <div className={classNames("grid grid-flow-col justify-between gap-4", className)}>
      <h4 className="inline-flex flex-wrap gap-2">{title}</h4>
      <div>
        {useExpandedCurrencySymbol
          ? formatUSDCentsWithExpandedCurrencySymbol(Math.floor(price))
          : `$${formatPriceCentsWithoutCurrencySymbol("usd", price)}`}
      </div>
    </div>
  );
}
