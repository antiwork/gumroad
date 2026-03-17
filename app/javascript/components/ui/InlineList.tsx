import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const InlineList = React.forwardRef<HTMLUListElement, React.HTMLAttributes<HTMLUListElement>>(
  ({ className, ...props }, ref) => (
    <ul
      ref={ref}
      className={classNames("list-none p-0 [&>li]:inline [&>li:not(:last-child)]:after:content-['_·_']", className)}
      {...props}
    />
  ),
);
InlineList.displayName = "InlineList";
