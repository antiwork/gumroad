import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Separator = ({
  children,
  className,
  ...rest
}: React.PropsWithChildren<React.HTMLAttributes<HTMLDivElement>>) => (
  <div
    {...rest}
    role="separator"
    className={classNames(
      "override grid grid-cols-[1fr_auto_1fr] items-center gap-3 before:content-[''] before:[border-bottom:solid_1px_rgb(var(--parent-color)/var(--border-alpha))] after:content-[''] after:[border-bottom:solid_1px_rgb(var(--parent-color)/var(--border-alpha))]",
      className,
    )}
  >
    {children}
  </div>
);
