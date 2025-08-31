import React from "react";

import { classNames } from "$app/utils/classNames";

function Skeleton({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="skeleton" className={classNames("animate-pulse rounded-md bg-slate-600", className)} {...props} />
  );
}

export { Skeleton };
