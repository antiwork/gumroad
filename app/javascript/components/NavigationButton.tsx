import { Link } from "@inertiajs/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { buttonVariants, NavigationButtonProps, useValidateClassName } from "$app/components/Button";

/*
    This component is for inertia specific navigation button,
    since the other NavigationButton is used in a lot of ssr pages  and we can't import inertia Link there
*/
export const NavigationButtonInertia = React.forwardRef<HTMLAnchorElement, NavigationButtonProps>(
  ({ className, color, outline, small, disabled, children, ...props }, ref) => {
    useValidateClassName(className);

    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";
    const size = small ? "sm" : "default";

    return (
      <Link
        className={classNames(
          buttonVariants({ variant, size, color: color && !outline ? color : undefined }),
          className,
          "no-underline",
        )}
        ref={ref}
        inert={disabled}
        href={props.href ?? ""}
      >
        {children}
      </Link>
    );
  },
);
NavigationButtonInertia.displayName = "NavigationButtonInertia";
