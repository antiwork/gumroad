import { X } from "@boxicons/react";
import * as React from "react";
import typia from "typia";

import { classNames } from "$app/utils/classNames";

import { Alert } from "$app/components/ui/Alert";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";

const ALERT_KEY = "alert";

// How long a toast stays on screen before it dismisses itself. Exported so tests can identify the
// dismiss timer by its delay without duplicating the literal.
export const DISMISS_DELAY_MS = 5000;

export type AlertPayload = { message: string; status: "success" | "danger" | "info" | "warning"; html?: boolean };

const ToastAlert = ({ initial }: { initial: AlertPayload | null }) => {
  const [alert, setAlert] = React.useState<AlertPayload | null>(initial);
  const [isVisible, setIsVisible] = React.useState(!!initial);
  const [isClosing, setIsClosing] = React.useState(false);
  const timerRef = React.useRef<number | null>(null);
  const isHoveringRef = React.useRef(false);

  const clearTimer = () => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  };

  const dismiss = () => {
    clearTimer();
    setIsClosing(true);
    setIsVisible(false);
  };

  const startTimer = () => {
    clearTimer();
    timerRef.current = window.setTimeout(() => setIsVisible(false), DISMISS_DELAY_MS);
  };

  useGlobalEventListener("message", (event: MessageEvent) => {
    if (event.origin !== window.location.origin) return;
    if (typia.is<{ type: "alert"; payload: AlertPayload }>(event.data)) {
      const newAlert = event.data.payload;
      setAlert(newAlert);
      setIsClosing(false);
      setIsVisible(true);
      if (!isHoveringRef.current) startTimer();
    }
  });

  // Deliberately a plain useEffect rather than useRunOnce: the initial dismiss timeout has to be
  // cleared on unmount, and useRunOnce cannot honour a returned cleanup. The same cleanup also
  // covers timers started later via the postMessage path above.
  React.useEffect(() => {
    if (initial) startTimer();
    return clearTimer;
    // Mount-once for the initial payload, matching the previous useRunOnce contract.
  }, []);

  return (
    <div
      data-testid="toast-alert"
      className={classNames(
        "fixed top-4 left-1/2 z-100 w-max max-w-[calc(100vw-2rem)] rounded bg-background md:max-w-md",
        isVisible ? "visible" : "invisible",
      )}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: isClosing ? "all 0.15s ease-out" : "all 0.3s ease-out 0.5s",
      }}
      onMouseEnter={() => {
        isHoveringRef.current = true;
        clearTimer();
      }}
      onMouseLeave={() => {
        isHoveringRef.current = false;
        if (isVisible) startTimer();
      }}
    >
      <Alert variant={alert?.status}>
        <div className="flex items-start gap-2">
          <div className="flex-1" dangerouslySetInnerHTML={alert?.html ? { __html: alert.message } : undefined}>
            {!alert?.html ? alert?.message : null}
          </div>
          <button
            type="button"
            className="relative flex size-[1lh] shrink-0 cursor-pointer items-center justify-center text-muted all-unset before:absolute before:-inset-2 before:content-[''] hover:text-primary"
            aria-label="Close"
            onClick={dismiss}
          >
            <X className="size-4" />
          </button>
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
