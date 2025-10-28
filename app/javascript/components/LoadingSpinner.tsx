import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const LoadingSpinner = ({ className, ...props }: React.HTMLAttributes<HTMLElement>) => (
  <div
    className={classNames("inline-block size-[1em] animate-spin bg-(image:--loading-spinner) bg-cover", className)}
    role="progressbar"
    {...props}
  />
);
