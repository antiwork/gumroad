import * as React from "react";

import { classNames } from "$app/utils/classNames";

type Props = {
  children: React.ReactNode;
  className?: string;
};

export const Dropdown = ({ children, className }: Props) => (
  <div className="relative mb-2">
    <span className="absolute z-30 mt-px translate-x-full border-x-8 border-b-8 border-x-transparent border-b-border" />
    <div
      className={classNames("relative top-2 grid gap-2 rounded-sm border border-border bg-background p-4", className)}
    >
      {children}
    </div>
  </div>
);
