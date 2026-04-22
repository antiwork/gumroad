import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Logo = ({ className, ...props }: React.ComponentPropsWithoutRef<"span">) => (
  <span
    className={classNames(
      // Deliberately using an aspect ratio that adds vertical padding, so that the logo aligns with text
      "inline-block aspect-115/22 h-[1lh] shrink-0 bg-current mask-(--logo) mask-contain mask-center mask-no-repeat selection:bg-transparent selection:text-transparent",
      className,
    )}
    {...props}
  >
    Gumroad
  </span>
);
