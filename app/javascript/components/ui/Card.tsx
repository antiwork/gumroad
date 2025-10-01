import * as React from "react";

import { classNames } from "$app/utils/classNames";

export function Card({ children, className, ...props }: React.HTMLProps<HTMLDivElement>) {
  return (
    <div
      className={classNames(
        "border-parentBorder bg-filled text-contrastFilled grid gap-4 rounded-lg border border-solid p-4",
        className,
      )}
      {...props}
    >
      {children}
    </div>
  );
}
