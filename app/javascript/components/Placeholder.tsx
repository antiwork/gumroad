import * as React from "react";

import { classNames } from "$app/utils/classNames";

interface PlaceholderProps {
  children: React.ReactNode;
  className?: string;
}

export const Placeholder: React.FC<PlaceholderProps> = ({ children, className }) => (
  <div
    className={classNames(
      "grid justify-items-center gap-3 rounded border border-dashed border-[rgb(var(--parent-color)/var(--border-alpha))] bg-[rgb(var(--filled))] p-8 text-center",
      // Icon styling for direct children
      "[&>.icon]:text-4xl [&>svg]:text-4xl",
      className,
    )}
  >
    {children}
  </div>
);
