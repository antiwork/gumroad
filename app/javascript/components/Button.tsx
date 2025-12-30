import { cva } from "class-variance-authority";
import * as React from "react";
import { is } from "ts-safe-cast";

import { assert } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { ButtonColor, buttonColors } from "$app/components/design";

export const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 rounded border border-solid border-transparent font-inherit no-underline transition-transform duration-[0.14s] ease-out disabled:opacity-30 disabled:pointer-events-none disabled:cursor-default hover:not-active:not-disabled:-translate-y-1 hover:not-active:not-disabled:-translate-x-1 hover:not-active:not-disabled:shadow-[0.25rem_0.25rem_0_currentColor]",
  {
    variants: {
      variant: {
        default: "bg-transparent text-current",
        outline: "bg-gray text-current border-current", // outline uses background-color: gray(2) per original SCSS mixin bg-bordered
        secondary: "bg-transparent text-muted", // Assuming secondary was similar to default or muted
        destructive: "bg-danger text-danger-foreground",
      },
      size: {
        default: "text-[length:var(--font-size-2)] leading-[length:var(--line-height-2)] px-4 py-3",
        sm: "text-[1rem] leading-[1.4] p-2",
      },
      color: {
        primary: "bg-primary text-primary-foreground border-primary",
        black: "bg-black text-white border-black",
        accent: "bg-accent text-accent-foreground border-accent",
        filled: "bg-white text-black border-white",
        success: "bg-success text-success-foreground border-success",
        danger: "bg-danger text-danger-foreground border-danger",
        warning: "bg-warning text-warning-foreground border-warning",
        info: "bg-info text-info-foreground border-info",
      },
    },
    compoundVariants: [
      {
        variant: "outline",
        color: "primary",
        className: "bg-transparent border-primary text-primary hover:bg-primary hover:text-primary-foreground",
      },
      {
        variant: "outline",
        color: "danger",
        className: "bg-transparent border-danger text-danger hover:bg-danger hover:text-danger-foreground",
      },
      {
        variant: "outline",
        color: "success",
        className: "bg-transparent border-success text-success hover:bg-success hover:text-success-foreground",
      },
      {
        variant: "outline",
        color: "warning",
        className: "bg-transparent border-warning text-warning hover:bg-warning hover:text-warning-foreground",
      },
      {
        variant: "outline",
        color: "info",
        className: "bg-transparent border-info text-info hover:bg-info hover:text-info-foreground",
      },
      {
        variant: "outline",
        color: "black",
        className: "bg-transparent border-black text-black hover:bg-black hover:text-white",
      },
      {
        variant: "outline",
        color: "accent",
        className: "bg-transparent border-accent text-accent hover:bg-accent hover:text-accent-foreground",
      },
      {
        variant: "outline",
        color: "filled",
        className: "bg-transparent border-white text-white hover:bg-white hover:text-black",
      },
    ],
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  },
);

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
export const useValidateClassName = (className: string | undefined) => {
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
