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
        "bg-filled fixed left-1/2 top-4 w-max max-w-[calc(100vw-2rem)] px-4 py-2 md:max-w-sm",
        alert?.status,
        isVisible ? "visible" : "invisible",
      )}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: "all 0.3s ease-out 0.5s",
        zIndex: "var(--z-index-tooltip)",
      }}
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
