import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Avatar = ({ className, ...props }: React.ImgHTMLAttributes<HTMLImageElement>) => (
  <img className={classNames("aspect-square w-5 shrink-0 rounded-full border border-border", className)} {...props} />
);
