import * as React from "react";

import { classNames } from "$app/utils/classNames";

import loadingSpinner from "$assets/images/loading-rainbow.svg";

export const LoadingSpinner = ({ className, ...props }: React.HTMLAttributes<HTMLElement>) => (
  <img
    src={loadingSpinner}
    className={classNames("size-[1em] animate-spin", className)}
    role="progressbar"
    {...props}
  />
);
