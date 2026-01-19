import * as React from "react";

import { classNames } from "$app/utils/classNames";

type BaseProps = {
  children: React.ReactNode;
  className?: string;
} & React.HTMLAttributes<HTMLElement>;

export const ProductCard = ({ children, className, ...props }: BaseProps) => (
  <article
    className={classNames(
      "relative flex flex-col rounded bg-background transition-all duration-150 hover:scale-[1.01]",
      className,
    )}
    {...props}
  >
    {children}
  </article>
);

export const ProductCardFigure = ({ children, className, ...props }: BaseProps) => (
  <figure
    className={classNames(
      "aspect-square overflow-hidden rounded-t bg-(image:--product-cover-placeholder) bg-cover",
      "[&_img]:size-full [&_img]:object-cover",
      className,
    )}
    {...props}
  >
    {children}
  </figure>
);

export const ProductCardHeader = ({ children, className, ...props }: BaseProps) => (
  <header className={classNames("flex flex-1 flex-col gap-1 p-4", className)} {...props}>
    {children}
  </header>
);

export const ProductCardFooter = ({ children, className, ...props }: BaseProps) => (
  <footer className={classNames("flex divide-x divide-border", className)} {...props}>
    {children}
  </footer>
);
