import React from "react";

import { classNames } from "$app/utils/classNames";

function Skeleton({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="skeleton"
      className={classNames("bg-foreground/10 animate-pulse rounded-md", className)}
      {...props}
    />
  );
}

export { Skeleton };
