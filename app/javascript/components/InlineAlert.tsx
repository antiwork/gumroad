import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

type AlertVariant = "success" | "danger" | "warning" | "info";

const ALERT_STYLES = {
  success: {
    icon: "solid-check-circle" as const,
    container: "border-alert-success bg-green-50 dark:bg-green-950",
    iconColor: "text-alert-success",
  },
  danger: {
    icon: "x-circle-fill" as const,
    container: "border-alert-danger bg-red-50 dark:bg-red-950",
    iconColor: "text-alert-danger",
  },
  warning: {
    icon: "solid-shield-exclamation" as const,
    container: "border-alert-warning bg-yellow-50 dark:bg-yellow-950",
    iconColor: "text-alert-warning",
  },
  info: {
    icon: "info-circle-fill" as const,
    container: "border-alert-info bg-blue-50 dark:bg-blue-950",
    iconColor: "text-alert-info",
  },
};

type InlineAlertProps = {
  variant: AlertVariant;
  children: React.ReactNode;
  role?: "alert" | "status";
  className?: string;
};

export const InlineAlert = ({ variant, children, role = "alert", className }: InlineAlertProps) => {
  const styles = ALERT_STYLES[variant];

  return (
    <div
      role={role}
      className={classNames("flex items-start gap-2 rounded border px-4 py-2", styles.container, className)}
    >
      <Icon name={styles.icon} className={classNames("mt-0.5 w-4", styles.iconColor)} />
      <div>{children}</div>
    </div>
  );
};

export default InlineAlert;
