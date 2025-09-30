import * as React from "react";

export const Separator = ({ children, ...rest }: React.PropsWithChildren<React.HTMLAttributes<HTMLDivElement>>) => (
  <div
    {...rest}
    role="separator"
    className="override grid grid-cols-[1fr_auto_1fr] items-center gap-3 before:content-[''] before:[border-bottom:solid_.0625rem_rgb(var(--parent-color)/var(--border-alpha))] after:content-[''] after:[border-bottom:solid_.0625rem_rgb(var(--parent-color)/var(--border-alpha))]"
  >
    {children}
  </div>
);
