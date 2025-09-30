import * as React from "react";

export const Separator = ({ children, ...rest }: React.PropsWithChildren<React.HTMLAttributes<HTMLDivElement>>) => (
  <div
    {...rest}
    role="separator"
    className="override grid grid-cols-[1fr_auto_1fr] items-center gap-3 before:border-b before:border-solid before:border-[rgb(var(--parent-color)/var(--border-alpha))] before:content-[''] after:border-b after:border-solid after:border-[rgb(var(--parent-color)/var(--border-alpha))] after:content-['']"
  >
    {children}
  </div>
);
