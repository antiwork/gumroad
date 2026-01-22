import * as React from "react";

import { classNames } from "$app/utils/classNames";

type PlaceholderProps = React.PropsWithChildren<{
  className?: string;
  role?: string;
  "aria-label"?: string;
  style?: React.CSSProperties;
}>;

export const Placeholder: React.FC<PlaceholderProps> = ({ className, children, ...rest }) => (
  <div
    className={classNames(
      "grid justify-items-center gap-3 rounded border border-dashed border-border bg-background p-6 text-center",
      "[&>.icon]:text-xl",
      className,
    )}
    {...rest}
  >
    {children}
  </div>
);

export const PlaceholderImage = ({ className, src, ...imgProps }: React.ImgHTMLAttributes<HTMLImageElement>) => (
  <figure className="w-full">
    <img src={src} className={classNames("w-full", className)} role="presentation" {...imgProps} />
  </figure>
);
