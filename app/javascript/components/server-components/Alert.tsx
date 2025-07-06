import cx from "classnames";
import * as React from "react";
import { is } from "ts-safe-cast";

import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";

type AlertPayload = { message: string; status: "success" | "danger" | "info" | "warning"; html?: boolean };

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

  return (
    <div
      role="alert"
      className={cx(
        "bg-filled fixed right-1/2 top-4 transform translate-x-1/2 transition-all duration-300 ease-out delay-500 z-30 px-4 py-3 rounded-lg shadow-lg border border-gray-300 dark:border-gray-600",
        alert?.status,
        isVisible ? "visible translate-y-0" : "invisible -translate-y-[calc(100%+1rem)]"
      )}
      dangerouslySetInnerHTML={alert?.html ? { __html: alert.message } : undefined}
    >
      {!alert?.html ? alert?.message : null}
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
