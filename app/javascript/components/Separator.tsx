import * as React from "react";

export const Separator = ({ children, ...rest }: React.PropsWithChildren<React.HTMLAttributes<HTMLDivElement>>) => (
  <div
    {...rest}
    role="separator"
    className="before:border-gray-300 after:border-gray-300 grid grid-cols-[1fr_auto_1fr] items-center gap-3 before:border-b before:content-[''] after:border-b after:content-['']"
  >
    {children}
  </div>
);
