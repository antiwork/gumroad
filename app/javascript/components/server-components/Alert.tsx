import cx from "classnames";
import * as React from "react";
import { is } from "ts-safe-cast";
import { cast } from "ts-safe-cast";

import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";

export type AlertPayload = { message: string; status: "success" | "danger" | "info" | "warning"; html?: boolean };

const icons = require.context("$assets/images/icons/");

const ALERT_CONFIG = {
  success: {
    icon: cast(icons("./solid-check-circle.svg")),
  },
  danger: {
    icon: cast(icons("./x-circle-fill.svg")),
  },
  warning: {
    icon: cast(icons("./solid-shield-exclamation.svg")),
  },
  info: {
    icon: cast(icons("./info-circle-fill.svg")),
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

  return (
    <div
      role="alert"
      className={cx(
        "fixed top-4 left-1/2 z-[9999] -translate-x-1/2",
        "min-h-10 w-max max-w-[calc(100vw-2rem)] md:max-w-sm",
        "flex items-center gap-3 rounded border p-3",
        "transition-all delay-500 duration-300 ease-out",
        {
          "border-[rgb(var(--success))] bg-[rgb(var(--success)/20%)]": alert.status === "success",
          "border-[rgb(var(--danger))] bg-[rgb(var(--danger)/20%)]": alert.status === "danger",
          "border-[rgb(var(--warning))] bg-[rgb(var(--warning)/20%)]": alert.status === "warning",
          "border-[rgb(var(--info))] bg-[rgb(var(--info)/20%)]": alert.status === "info",
        },
        isVisible ? "pointer-events-auto translate-y-0 opacity-100" : "pointer-events-none -translate-y-16 opacity-0",
      )}
    >
      <div
        className={cx(
          "h-5 w-5 flex-shrink-0",
          "[mask-size:contain] [mask-position:center] [mask-repeat:no-repeat]",
          "[-webkit-mask-position:center] [-webkit-mask-repeat:no-repeat] [-webkit-mask-size:contain]",
          {
            "bg-[rgb(var(--success))] [mask-image:var(--success-icon)] [-webkit-mask-image:var(--success-icon)]":
              alert.status === "success",
            "bg-[rgb(var(--danger))] [mask-image:var(--danger-icon)] [-webkit-mask-image:var(--danger-icon)]":
              alert.status === "danger",
            "bg-[rgb(var(--warning))] [mask-image:var(--warning-icon)] [-webkit-mask-image:var(--warning-icon)]":
              alert.status === "warning",
            "bg-[rgb(var(--info))] [mask-image:var(--info-icon)] [-webkit-mask-image:var(--info-icon)]":
              alert.status === "info",
          },
        )}
        style={
          {
            "--success-icon": `url(${ALERT_CONFIG.success.icon})`,
            "--danger-icon": `url(${ALERT_CONFIG.danger.icon})`,
            "--warning-icon": `url(${ALERT_CONFIG.warning.icon})`,
            "--info-icon": `url(${ALERT_CONFIG.info.icon})`,
          } as React.CSSProperties
        }
      />
      {alert.html ? <div dangerouslySetInnerHTML={{ __html: alert.message }} /> : <div>{alert.message}</div>}
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
