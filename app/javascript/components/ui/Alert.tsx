import { AlertShield, CheckCircle, InfoCircle, XCircle, type BoxIconProps } from "@boxicons/react";
import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

// A tint and an icon carry the meaning, as in the emails' callouts; the border only keeps the box size.
const alertVariants = cva("flex items-start gap-2 rounded-(--radius-box) border border-border p-3", {
  variants: {
    variant: {
      success: "border-transparent bg-success/20",
      danger: "border-transparent bg-danger/20",
      warning: "border-transparent bg-warning/20",
      info: "border-transparent bg-info/20",
      accent: "border-transparent bg-accent/20",
    },
  },
});

type AlertVariant = NonNullable<VariantProps<typeof alertVariants>["variant"]>;

const alertIcons = {
  success: CheckCircle,
  danger: XCircle,
  warning: AlertShield,
  info: InfoCircle,
} satisfies Record<Exclude<AlertVariant, "accent">, React.ComponentType<BoxIconProps>>;

const iconColorVariants = cva("size-[1lh]!", {
  variants: {
    variant: {
      success: "text-success",
      danger: "text-danger",
      warning: "text-warning",
      info: "text-info",
    },
  },
});

export interface AlertProps extends React.HTMLProps<HTMLDivElement> {
  asChild?: boolean;
  children: React.ReactNode;
  variant?: Exclude<VariantProps<typeof alertVariants>["variant"], null>;
}

export const Alert = React.forwardRef<HTMLDivElement, AlertProps>(
  ({ className, children, role = "alert", variant, ...props }, ref) => (
    <div ref={ref} role={role} className={classNames(alertVariants({ variant }), className)} {...props}>
      {variant && variant !== "accent"
        ? (() => {
            const AlertIcon = alertIcons[variant];
            return <AlertIcon pack="filled" className={iconColorVariants({ variant })} aria-hidden="true" />;
          })()
        : null}
      <div className="flex-1">{children}</div>
    </div>
  ),
);
Alert.displayName = "Alert";
