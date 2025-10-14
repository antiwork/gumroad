import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const PageHeader = React.forwardRef<
  HTMLDivElement,
  {
    title: React.ReactNode;
    actions?: React.ReactNode;
    children?: React.ReactNode;
    className?: string;
  }
>(({ title, actions, children, className }, ref) => (
  <header className={classNames("flex flex-col gap-4 border-b border-border p-4 md:p-8", className)} ref={ref}>
    <div className="flex items-center justify-between gap-2">
      <h1 className="hidden! text-2xl sm:block!">{title}</h1>
      <div className="grid flex-1 grid-cols-2 gap-2 has-[>*:only-child]:grid-cols-1 sm:flex sm:flex-none md:-my-2">
        {actions}
      </div>
    </div>
    {children}
  </header>
));

PageHeader.displayName = "PageHeader";
