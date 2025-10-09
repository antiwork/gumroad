import React from "react";

import { classNames } from "$app/utils/classNames";

function Skeleton({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="skeleton"
      className={classNames("animate-pulse rounded-md bg-foreground/10", className)}
      {...props}
    />
  );
}

export { Skeleton };
