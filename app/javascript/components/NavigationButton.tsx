import { Link } from "@inertiajs/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { buttonVariants, NavigationButtonProps, useValidateClassName } from "$app/components/Button";

/*
    This component is for inertia specific navigation button,
    since the other NavigationButton is used in a lot of ssr pages  and we can't import inertia Link there
*/

type NavigationButtonInertiaProps = NavigationButtonProps & {
  data?: Record<string, string | number | boolean | null | undefined | string[] | number[] | boolean[]>;
  method?: "get" | "post" | "patch" | "put" | "delete";
  only?: string[];
  except?: string[];
  preserveScroll?: boolean;
  preserveState?: boolean;
  preserveUrl?: boolean;
  onStart?: (event: DocumentEventMap["inertia:start"]) => void;
  onSuccess?: (event: DocumentEventMap["inertia:success"]) => void;
  onError?: (event: DocumentEventMap["inertia:error"]) => void;
  onProgress?: (event: DocumentEventMap["inertia:progress"]) => void;
  onFinish?: (event: DocumentEventMap["inertia:finish"]) => void;
};

export const NavigationButtonInertia = React.forwardRef<HTMLAnchorElement, NavigationButtonInertiaProps>(
  ({ className, color, outline, small, disabled, children, onClick, style, inert, ...props }, ref) => {
    useValidateClassName(className);

    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";
    const size = small ? "sm" : "default";

    const filteredProps = Object.fromEntries(Object.entries(props).filter(([_, value]) => value !== undefined));

    const isAnchorEvent = (event: React.MouseEvent): event is React.MouseEvent<HTMLAnchorElement> =>
      event.currentTarget instanceof HTMLAnchorElement;

    const handleClick = onClick
      ? (event: React.MouseEvent) => {
          if (isAnchorEvent(event)) {
            onClick(event);
          }
        }
      : undefined;

    return (
      <Link
        className={classNames(
          buttonVariants({ variant, size, color: color && !outline ? color : undefined }),
          className,
          "no-underline",
        )}
        ref={ref}
        inert={disabled}
        {...filteredProps}
        {...(handleClick && { onClick: handleClick })}
        style={{
          ...style,
          ...(disabled ? { pointerEvents: "none", cursor: "not-allowed", opacity: 0.3 } : {}),
        }}
      >
        {children}
      </Link>
    );
  },
);
NavigationButtonInertia.displayName = "NavigationButtonInertia";
