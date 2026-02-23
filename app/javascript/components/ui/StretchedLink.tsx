import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

export interface StretchedLinkProps extends React.AnchorHTMLAttributes<HTMLAnchorElement> {
  asChild?: boolean;
}

export const StretchedLink = React.forwardRef<HTMLAnchorElement, StretchedLinkProps>(
  ({ className, asChild = false, ...props }, ref) => {
    const Component = asChild ? Slot : "a";
    return (
      <Component
        ref={ref}
        className={classNames("no-underline before:absolute before:inset-0 before:content-['']", className)}
        {...props}
      />
    );
  },
);
StretchedLink.displayName = "StretchedLink";
