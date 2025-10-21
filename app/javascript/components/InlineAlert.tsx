import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { Icon } from "$app/components/Icons";

type AlertVariant = "success" | "danger" | "warning" | "info";

const ALERT_STYLES = {
  success: {
    icon: "solid-check-circle" as const,
    container: "border-alert-success bg-alert-success/20",
    iconColor: "text-alert-success",
  },
  danger: {
    icon: "x-circle-fill" as const,
    container: "border-alert-danger bg-alert-danger/20",
    iconColor: "text-alert-danger",
  },
  warning: {
    icon: "solid-shield-exclamation" as const,
    container: "border-alert-warning bg-alert-warning/20",
    iconColor: "text-alert-warning",
  },
  info: {
    icon: "info-circle-fill" as const,
    container: "border-alert-info bg-alert-info/20",
    iconColor: "text-alert-info",
  },
};

type InlineAlertProps = {
  variant: AlertVariant;
  children: React.ReactNode;
  role?: "alert" | "status";
  className?: string;
  showIcon?: boolean;
};

export const InlineAlert = ({ variant, children, role = "alert", className, showIcon = true }: InlineAlertProps) => {
  const styles = ALERT_STYLES[variant];

  return (
    <div
      role={role}
      className={classNames(
        "grid items-center gap-2 rounded border px-4 py-2",
        showIcon ? "grid-cols-[auto_1fr]" : "",
        styles.container,
        className,
      )}
    >
      {showIcon && <Icon name={styles.icon} className={classNames("min-h-[1lh] w-[1em]", styles.iconColor)} />}
      <div>{children}</div>
    </div>
  );
};

export default InlineAlert;
