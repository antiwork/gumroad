import { Slot } from "@radix-ui/react-slot";
import { cva } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { ButtonColor } from "$app/components/design";

export const brandNames = [
  "paypal",
  "discord",
  "stripe",
  "facebook",
  "twitter",
  "apple",
  "android",
  "kindle",
  "zoom",
  "google",
] as const;

export type BrandName = (typeof brandNames)[number];

export const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 cursor-pointer border border-border rounded text-current font-[inherit] no-underline transition-transform hover:-translate-1 hover:shadow active:translate-0 active:shadow-none disabled:opacity-30 disabled:hover:translate-0 disabled:hover:shadow-none",
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
        default: "bg-transparent",
        primary: "bg-primary text-primary-foreground hover:bg-accent hover:text-accent-foreground",
        black: "bg-black text-white",
        accent: "bg-accent text-accent-foreground",
        filled: "bg-background text-foreground",
        success: "bg-success text-white",
        danger: "bg-danger text-white",
        warning: "bg-warning text-black",
        info: "bg-primary text-primary-foreground",
        paypal: "bg-[#00457c] text-white border-[#00457c]",
        discord: "bg-[#7289da] text-white border-[#7289da]",
        stripe: "bg-[#625bf6] text-white border-[#625bf6]",
        facebook: "bg-[#4267b2] text-white border-[#4267b2]",
        twitter: "bg-black text-white",
        apple: "bg-black text-white",
        android: "bg-[#142f40] text-white",
        kindle: "bg-[#f3a642] text-black border-[#f3a642]",
        zoom: "bg-[#4087fc] text-white border-[#4087fc]",
        google: "bg-[#5383ec] text-white border-[#5383ec]",
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
        className: "bg-transparent text-current hover:bg-danger hover:text-white",
      },
      {
        variant: "outline",
        color: "success",
        className: "bg-transparent text-current hover:bg-success hover:text-white",
      },
      {
        variant: "outline",
        color: "warning",
        className: "bg-transparent text-current hover:bg-warning hover:text-black",
      },
      {
        variant: "outline",
        color: "info",
        className: "bg-transparent text-current hover:bg-primary hover:text-primary-foreground",
      },
      {
        variant: "outline",
        color: "black",
        className: "bg-transparent text-current hover:bg-black hover:text-white",
      },
      {
        variant: "outline",
        color: "accent",
        className: "bg-transparent text-current hover:bg-accent hover:text-accent-foreground",
      },
      {
        variant: "outline",
        color: "filled",
        className: "bg-transparent text-black hover:bg-white hover:text-black",
      },
    ],
    defaultVariants: {
      variant: "default",
      size: "default",
      color: "default",
    },
  },
);

// Legacy props for backward compatibility
type ButtonVariation = {
  color?: ButtonColor | BrandName | undefined;
  outline?: boolean | undefined;
  small?: boolean | undefined;
};

export interface ButtonProps extends Omit<React.ComponentPropsWithoutRef<"button">, "color">, ButtonVariation {
  asChild?: boolean;
}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, color, outline, small, disabled, children, asChild = false, ...props }, ref) => {
    const variant = outline ? "outline" : color === "danger" ? "destructive" : "default";
    const size = small ? "sm" : "default";

    const classes = classNames(buttonVariants({ variant, size, color: color || undefined }), className);
    const Comp = asChild ? Slot : "button";

    return (
      <Comp className={classes} ref={ref} disabled={disabled} type={asChild ? undefined : "button"} {...props}>
        {children}
      </Comp>
    );
  },
);
Button.displayName = "Button";

export interface NavigationButtonProps extends Omit<React.ComponentPropsWithoutRef<"a">, "color">, ButtonVariation {
  disabled?: boolean | undefined;
}

export const NavigationButton = React.forwardRef<HTMLAnchorElement, NavigationButtonProps>(
  ({ className, color, outline, small, disabled, children, ...props }, ref) => (
    <Button asChild className={className} color={color} outline={outline} small={small} disabled={disabled}>
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
