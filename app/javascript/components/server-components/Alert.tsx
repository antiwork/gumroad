import * as React from "react";
import { is } from "ts-safe-cast";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";

export type AlertPayload = { message: string; status: "success" | "danger" | "info" | "warning"; html?: boolean };

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

const Alert = ({ initial }: { initial: AlertPayload | null }) => {
  const [alert, setAlert] = React.useState<AlertPayload | null>(initial);
  const [isVisible, setIsVisible] = React.useState(!!initial);
  const timerRef = React.useRef<number | null>(null);

  const clearTimer = () => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  };

  const startTimer = () => {
    clearTimer();
    timerRef.current = window.setTimeout(() => setIsVisible(false), 5000);
  };

  useGlobalEventListener("message", (event: MessageEvent) => {
    if (event.origin !== window.location.origin) return;
    if (is<{ type: "alert"; payload: AlertPayload }>(event.data)) {
      const newAlert = event.data.payload;
      setAlert(newAlert);
      setIsVisible(true);
      startTimer();
    }
  });
  useRunOnce(() => {
    if (initial) startTimer();
  });

  if (!alert) return null;

  const styles = ALERT_STYLES[alert.status];

  return (
    <div
      role="alert"
      className={classNames(
        "fixed top-4 left-1/2 w-max max-w-sm -translate-x-1/2 px-2",
        "flex items-start gap-2 rounded border px-4 py-2",
        styles.container,
        isVisible ? "visible" : "invisible",
      )}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? 0 : "calc(-100% - 2rem)"})`,
        transition: "all 0.3s ease-out 0.5s",
        zIndex: 30,
      }}
    >
      <Icon name={styles.icon} className={classNames("mt-0.5 w-4", styles.iconColor)} />
      <div dangerouslySetInnerHTML={alert.html ? { __html: alert.message } : undefined}>
        {!alert.html ? alert.message : null}
      </div>
    </div>
  );
};

export const showAlert = (
  message: string,
  status: "success" | "error" | "info" | "warning",
  options: { html?: boolean } = { html: false },
) => {
  window.postMessage(
    {
      type: ALERT_KEY,
      payload: { message, status: status === "error" ? "danger" : status, html: options.html },
    },
    window.location.origin,
  );
};

export default Alert;
