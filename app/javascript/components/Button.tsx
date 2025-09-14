import { cva } from "class-variance-authority";
import * as React from "react";
import { is } from "ts-safe-cast";

import { assert } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { ButtonColor, buttonColors } from "$app/components/design";

const buttonVariants = cva("button", {
  variants: {
    variant: {
      default: "",
      outline: "",
      secondary: "",
      destructive: "",
    },
    size: {
      default: "",
      sm: "small",
    },
    color: {
      primary: "primary",
      black: "black",
      accent: "accent",
      filled: "filled",
      success: "success",
      danger: "danger",
      warning: "warning",
      info: "info",
    },
  },
  compoundVariants: [
    {
      variant: "outline",
      color: "primary",
      className: "outline-primary",
    },
    {
      variant: "outline",
      color: "danger",
      className: "outline-danger",
    },
    {
      variant: "outline",
      color: "success",
      className: "outline-success",
    },
    {
      variant: "outline",
      color: "warning",
      className: "outline-warning",
    },
    {
      variant: "outline",
      color: "info",
      className: "outline-info",
    },
    {
      variant: "outline",
      color: "black",
      className: "outline-black",
    },
    {
      variant: "outline",
      color: "accent",
      className: "outline-accent",
    },
    {
      variant: "outline",
      color: "filled",
      className: "outline-filled",
    },
  ],
  defaultVariants: {
    variant: "default",
    size: "default",
  },
});

// Legacy props for backward compatibility
type ButtonVariation = {
  color?: ButtonColor | undefined;
  outline?: boolean;
  small?: boolean;
};

export interface ButtonProps extends Omit<React.ComponentPropsWithoutRef<"button">, "color">, ButtonVariation {}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, color, outline, small, disabled, ...props }, ref) => {
    useValidateClassName(className);

    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";
    const size = small ? "sm" : "default";

    return (
      <button
        className={classNames(
          buttonVariants({ variant, size, color: color && !outline ? color : undefined }),
          className,
        )}
        ref={ref}
        disabled={disabled}
        type="button"
        {...props}
      />
    );
  },
);
Button.displayName = "Button";

export interface NavigationButtonProps extends Omit<React.ComponentPropsWithoutRef<"a">, "color">, ButtonVariation {
  disabled?: boolean | undefined;
}

export const NavigationButton = React.forwardRef<HTMLAnchorElement, NavigationButtonProps>(
  ({ className, color, outline, small, disabled, ...props }, ref) => {
    useValidateClassName(className);

    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";
    const size = small ? "sm" : "default";

    return (
      <a
        className={classNames(
          buttonVariants({ variant, size, color: color && !outline ? color : undefined }),
          className,
        )}
        ref={ref}
        inert={disabled}
        {...props}
        onClick={(evt) => {
          if (props.onClick == null) return;

          if (props.href == null || props.href === "#") evt.preventDefault();

          props.onClick(evt);

          evt.stopPropagation();
        }}
      />
    );
  },
);
NavigationButton.displayName = "NavigationButton";

// Logs warnings whenever `className` changes, instead of on every render
const useValidateClassName = (className: string | undefined) => {
  if (process.env.NODE_ENV === "production") return;

  React.useEffect(() => validateClassName(className), [className]);
};

// Display warnings when trying to use color/variant/size as class name, suggesting a prop to use instead
const validateClassName = (className: string | undefined) => {
  if (process.env.NODE_ENV === "production") return;

  if (className == null) return;

  const classes = className.split(" ");

  classes.forEach((cls) => {
    assert(cls !== "button", `Button: Using '${cls}' as 'className' prop is unnecessary`);
    assert(!is<ButtonColor>(cls), `Button: Instead of using '${cls}' as a class, use the 'color="${cls}"' prop`);
    assert(
      !buttonColors.some((color) => cls === `outline-${color}`),
      `Button: Instead of using '${cls}' as a class, use the 'color="${cls.replace(
        "outline-",
        "",
      )}" and the 'outline' prop`,
    );
    assert(cls !== "small", `Button: Instead of using '${cls}' as a class, use the 'small' prop`);
  });
};
