import { Link } from "@inertiajs/react";
import type { VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Button, buttonVariants, type ButtonVariation } from "$app/components/Button";

export interface NavigationButtonProps extends Omit<React.ComponentPropsWithoutRef<"a">, "color">, ButtonVariation {
  size?: VariantProps<typeof buttonVariants>["size"];
  disabled?: boolean | undefined;
}

export const NavigationButton = React.forwardRef<HTMLAnchorElement, NavigationButtonProps>(
  ({ className, color, outline, size, disabled, children, ...props }, ref) => (
    <Button asChild className={className} color={color} outline={outline} size={size} disabled={disabled}>
      <a
        ref={ref}
        inert={disabled}
        {...props}
        onClick={(evt) => {
          if (props.onClick == null) return;

          if (props.href == null || props.href === "#") evt.preventDefault();

          props.onClick(evt);

          evt.stopPropagation();
        }}
      >
        {children}
      </a>
    </Button>
  ),
);
NavigationButton.displayName = "NavigationButton";

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
  ({ className, color, outline, size, disabled, children, onClick, inert, ...props }, ref) => {
    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";

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
          disabled && "pointer-events-none opacity-30",
        )}
        ref={ref}
        inert={disabled}
        {...filteredProps}
        {...(handleClick && { onClick: handleClick })}
      >
        {children}
      </Link>
    );
  },
);
NavigationButtonInertia.displayName = "NavigationButtonInertia";
