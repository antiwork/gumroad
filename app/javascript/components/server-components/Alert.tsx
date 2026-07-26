import { X } from "@boxicons/react";
import * as React from "react";
import typia from "typia";

import { classNames } from "$app/utils/classNames";

import { Alert } from "$app/components/ui/Alert";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";
// Where showAlertAfterReload leaves a toast for the next document to pick up.
const PENDING_ALERT_STORAGE_KEY = "pendingAlert";

export type AlertPayload = { message: string; status: "success" | "danger" | "info" | "warning"; html?: boolean };

// A toast that showAlertAfterReload left behind, if any. Reading it also
// clears it, so it is shown exactly once.
const takePendingAlert = (): AlertPayload | null => {
  try {
    const stored = window.sessionStorage.getItem(PENDING_ALERT_STORAGE_KEY);
    if (stored === null) return null;
    window.sessionStorage.removeItem(PENDING_ALERT_STORAGE_KEY);
    const parsed: unknown = JSON.parse(stored);
    return typia.is<AlertPayload>(parsed) ? parsed : null;
  } catch {
    // sessionStorage can be unavailable (private browsing, blocked storage) and
    // the stored value can be anything. Neither is worth failing a page load over.
    return null;
  }
};

const ToastAlert = ({ initial }: { initial: AlertPayload | null }) => {
  // A toast queued right before the previous document reloaded takes precedence
  // over a server-rendered one: it is the outcome of what the seller just did.
  const [pending] = React.useState(takePendingAlert);
  const first = pending ?? initial;
  const [alert, setAlert] = React.useState<AlertPayload | null>(first);
  const [isVisible, setIsVisible] = React.useState(!!first);
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
    timerRef.current = window.setTimeout(() => setIsVisible(false), 5000);
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
  useRunOnce(() => {
    if (first) startTimer();
  });

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

const toPayload = (
  message: string,
  status: "success" | "error" | "info" | "warning",
  options: { html?: boolean },
): AlertPayload => ({
  message,
  status: status === "error" ? "danger" : status,
  ...(options.html === undefined ? {} : { html: options.html }),
});

export const showAlert = (
  message: string,
  status: "success" | "error" | "info" | "warning",
  options: { html?: boolean } = { html: false },
) => {
  window.postMessage({ type: ALERT_KEY, payload: toPayload(message, status, options) }, window.location.origin);
};

// Show a toast on the NEXT document instead of this one. showAlert delivers via
// window.postMessage, which is asynchronous — a caller that reloads or navigates
// straight after calling it unloads the document before the message is ever
// dispatched, so the toast is never seen. Callers that intend to reload should
// use this instead: the toast is parked in sessionStorage and the fresh page's
// ToastAlert picks it up (and clears it) on mount.
export const showAlertAfterReload = (
  message: string,
  status: "success" | "error" | "info" | "warning",
  options: { html?: boolean } = { html: false },
) => {
  try {
    window.sessionStorage.setItem(PENDING_ALERT_STORAGE_KEY, JSON.stringify(toPayload(message, status, options)));
  } catch {
    // Storage can be unavailable or full. The reload still has to happen, so
    // losing the toast is the acceptable outcome here.
  }
};

export default ToastAlert;
