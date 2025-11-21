import { cva } from "class-variance-authority";
import * as React from "react";
import { is } from "ts-safe-cast";

import { assert } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { ButtonColor, buttonColors } from "$app/components/design";

export type BrandName = "paypal" | "discord" | "stripe" | "facebook" | "twitter" | "apple" | "android" | "kindle" | "zoom" | "google";

const brandColors: Record<BrandName, { bg: string; text: string }> = {
  paypal: { bg: "#00457c", text: "#ffffff" },
  discord: { bg: "#7289da", text: "#ffffff" },
  stripe: { bg: "#625bf6", text: "#ffffff" },
  facebook: { bg: "#4267b2", text: "#ffffff" },
  twitter: { bg: "#000000", text: "#ffffff" },
  apple: { bg: "#000000", text: "#ffffff" },
  android: { bg: "#142f40", text: "#ffffff" },
  kindle: { bg: "#f3a642", text: "#000000" },
  zoom: { bg: "#4087fc", text: "#ffffff" },
  google: { bg: "#5383ec", text: "#ffffff" },
};

export const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 cursor-pointer border border-border rounded bg-transparent font-inherit no-underline transition-transform hover:-translate-x-1 hover:-translate-y-1 hover:shadow-[0.25rem_0.25rem_0_currentColor] active:translate-x-0 active:translate-y-0 active:shadow-none disabled:opacity-30 disabled:hover:translate-x-0 disabled:hover:translate-y-0 disabled:hover:shadow-none",
  {
    variants: {
      variant: {
        default: "",
        outline: "bg-transparent",
        secondary: "",
        destructive: "",
      },
      size: {
        default: "px-4 py-3 text-base leading-[1.4]",
        sm: "p-2 text-sm leading-[1.3]",
      },
      color: {
        primary: "bg-black text-white hover:bg-[rgb(var(--accent))] hover:text-[rgb(var(--contrast-accent))]",
        black: "bg-black text-white",
        accent: "bg-[rgb(var(--accent))] text-[rgb(var(--contrast-accent))]",
        filled: "bg-white text-black",
        success: "bg-[rgb(var(--success))] text-[rgb(var(--contrast-success))]",
        danger: "bg-[rgb(var(--danger))] text-[rgb(var(--contrast-danger))]",
        warning: "bg-[rgb(var(--warning))] text-[rgb(var(--contrast-warning))]",
        info: "bg-[rgb(var(--info))] text-[rgb(var(--contrast-info))]",
      },
    },
    compoundVariants: [
      {
        variant: "outline",
        color: "primary",
        className: "bg-transparent text-current hover:bg-black hover:text-white",
      },
      {
        variant: "outline",
        color: "danger",
        className: "bg-transparent text-current hover:bg-[rgb(var(--danger))] hover:text-[rgb(var(--contrast-danger))]",
      },
      {
        variant: "outline",
        color: "success",
        className: "bg-transparent text-current hover:bg-[rgb(var(--success))] hover:text-[rgb(var(--contrast-success))]",
      },
      {
        variant: "outline",
        color: "warning",
        className: "bg-transparent text-current hover:bg-[rgb(var(--warning))] hover:text-[rgb(var(--contrast-warning))]",
      },
      {
        variant: "outline",
        color: "info",
        className: "bg-transparent text-current hover:bg-[rgb(var(--info))] hover:text-[rgb(var(--contrast-info))]",
      },
      {
        variant: "outline",
        color: "black",
        className: "bg-transparent text-current hover:bg-black hover:text-white",
      },
      {
        variant: "outline",
        color: "accent",
        className: "bg-transparent text-current hover:bg-[rgb(var(--accent))] hover:text-[rgb(var(--contrast-accent))]",
      },
      {
        variant: "outline",
        color: "filled",
        className: "bg-transparent text-current hover:bg-white hover:text-black",
      },
    ],
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
);

// Legacy props for backward compatibility
type ButtonVariation = {
  color?: ButtonColor | undefined;
  outline?: boolean;
  small?: boolean;
  brand?: BrandName | undefined;
};

export interface ButtonProps extends Omit<React.ComponentPropsWithoutRef<"button">, "color">, ButtonVariation {}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, color, outline, small, brand, disabled, children, ...props }, ref) => {
    useValidateClassName(className);

    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";
    const size = small ? "sm" : "default";

    // If brand is specified, use brand colors
    const brandStyle = brand
      ? {
          backgroundColor: brandColors[brand].bg,
          color: brandColors[brand].text,
          borderColor: brandColors[brand].bg,
        }
      : undefined;

    return (
      <button
        className={classNames(
          buttonVariants({ variant, size, color: color && !outline && !brand ? color : undefined }),
          className,
        )}
        style={brandStyle}
        ref={ref}
        disabled={disabled}
        type="button"
        {...props}
      >
        {brand && <span className={`brand-icon brand-icon-${brand}`} />}
        {children}
      </button>
    );
  },
);
Button.displayName = "Button";

export interface NavigationButtonProps extends Omit<React.ComponentPropsWithoutRef<"a">, "color">, ButtonVariation {
  disabled?: boolean | undefined;
}

export const NavigationButton = React.forwardRef<HTMLAnchorElement, NavigationButtonProps>(
  ({ className, color, outline, small, brand, disabled, children, ...props }, ref) => {
    useValidateClassName(className);

    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";
    const size = small ? "sm" : "default";

    // If brand is specified, use brand colors
    const brandStyle = brand
      ? {
          backgroundColor: brandColors[brand].bg,
          color: brandColors[brand].text,
          borderColor: brandColors[brand].bg,
        }
      : undefined;

    return (
      <a
        className={classNames(
          buttonVariants({ variant, size, color: color && !outline && !brand ? color : undefined }),
          className,
        )}
        style={brandStyle}
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
        {brand && <span className={`brand-icon brand-icon-${brand}`} />}
        {children}
      </a>
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
