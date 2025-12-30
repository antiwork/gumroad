import * as React from "react";
import { is } from "ts-safe-cast";

import { classNames } from "$app/utils/classNames";

import { Alert } from "$app/components/ui/Alert";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";

export type AlertPayload = { message: string; status: "success" | "danger" | "info" | "warning"; html?: boolean };

const ToastAlert = ({ initial }: { initial: AlertPayload | null }) => {
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
      className={classNames(
        "fixed top-4 left-1/2 z-100 w-max max-w-[calc(100vw-2rem)] rounded bg-background md:max-w-sm",
        isVisible ? "visible" : "invisible",
      )}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: "all 0.3s ease-out 0.5s",
      }}
    >
      <Alert variant={alert?.status}>
        <div dangerouslySetInnerHTML={alert?.html ? { __html: alert.message } : undefined}>
          {!alert?.html ? alert?.message : null}
        </div>
      </Alert>
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

export default ToastAlert;
