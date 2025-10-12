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
    borderColor: "rgb(var(--success))",
    backgroundColor: "rgb(var(--success) / 20%)",
    iconColor: "rgb(var(--success))",
  },
  danger: {
    icon: cast(icons("./x-circle-fill.svg")),
    borderColor: "rgb(var(--danger))",
    backgroundColor: "rgb(var(--danger) / 20%)",
    iconColor: "rgb(var(--danger))",
  },
  warning: {
    icon: cast(icons("./solid-shield-exclamation.svg")),
    borderColor: "rgb(var(--warning))",
    backgroundColor: "rgb(var(--warning) / 20%)",
    iconColor: "rgb(var(--warning))",
  },
  info: {
    icon: cast(icons("./info-circle-fill.svg")),
    borderColor: "rgb(var(--info))",
    backgroundColor: "rgb(var(--info) / 20%)",
    iconColor: "rgb(var(--info))",
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

  const config = ALERT_CONFIG[alert.status];

  return (
    <div
      role="alert"
      className={cx(
        "fixed top-4 left-1/2 z-[9999]",
        "min-h-10 w-max max-w-[calc(100vw-2rem)] md:max-w-sm",
        "flex items-center gap-3 rounded border p-3",
        "transition-all delay-500 duration-300 ease-out",
        isVisible ? "pointer-events-auto opacity-100" : "pointer-events-none opacity-0",
      )}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? "0" : "-4rem"})`,
        borderColor: config.borderColor,
        backgroundColor: config.backgroundColor,
      }}
    >
      <div
        className="h-5 w-5 flex-shrink-0"
        style={{
          backgroundColor: config.iconColor,
          maskImage: `url(${config.icon})`,
          maskPosition: "center",
          maskSize: "contain",
          maskRepeat: "no-repeat",
          WebkitMaskImage: `url(${config.icon})`,
          WebkitMaskPosition: "center",
          WebkitMaskSize: "contain",
          WebkitMaskRepeat: "no-repeat",
        }}
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
