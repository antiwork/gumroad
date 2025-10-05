import cx from "classnames";
import * as React from "react";
import { is } from "ts-safe-cast";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";

type AlertPayload = { message: string; status: "success" | "danger" | "info" | "warning"; html?: boolean };

// Helper function to get alert classes
const getAlertClasses = (status: string) => {
  const baseClasses =
    "fixed left-1/2 top-4 w-max max-w-[calc(100vw-2rem)] px-4 py-2 md:max-w-sm border rounded flex items-start gap-2";

  switch (status) {
    case "success":
      return `${baseClasses} border-green-600 bg-green-600/20 text-green-800`;
    case "danger":
      return `${baseClasses} border-red-600 bg-red-600/20 text-red-800`;
    case "warning":
      return `${baseClasses} border-orange-600 bg-orange-600/20 text-orange-800`;
    case "info":
      return `${baseClasses} border-purple-600 bg-purple-600/20 text-purple-800`;
    default:
      return `${baseClasses} border-gray-600 bg-gray-600/20 text-gray-800`;
  }
};

// Helper function to get alert icons
const getAlertIcon = (status: string) => {
  const iconClasses = "w-5 h-5 mt-0.5 flex-shrink-0";

  switch (status) {
    case "success":
      return (
        <svg className={`${iconClasses} text-green-600`} fill="currentColor" viewBox="0 0 20 20">
          <path
            fillRule="evenodd"
            d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
            clipRule="evenodd"
          />
        </svg>
      );
    case "danger":
      return (
        <svg className={`${iconClasses} text-red-600`} fill="currentColor" viewBox="0 0 20 20">
          <path
            fillRule="evenodd"
            d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
            clipRule="evenodd"
          />
        </svg>
      );
    case "warning":
      return (
        <svg className={`${iconClasses} text-orange-600`} fill="currentColor" viewBox="0 0 20 20">
          <path
            fillRule="evenodd"
            d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
            clipRule="evenodd"
          />
        </svg>
      );
    case "info":
      return (
        <svg className={`${iconClasses} text-purple-600`} fill="currentColor" viewBox="0 0 20 20">
          <path
            fillRule="evenodd"
            d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
            clipRule="evenodd"
          />
        </svg>
      );
    default:
      return null;
  }
};

const Alert = ({ initial }: { initial: AlertPayload | null }) => {
  const [alert, setAlert] = React.useState(initial);
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
      className={cx(getAlertClasses(alert.status), isVisible ? "visible" : "invisible")}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: "all 0.3s ease-out 0.5s",
        zIndex: "var(--z-index-tooltip)",
      }}
    >
      {getAlertIcon(alert.status)}
      <div className="flex-1">
        {alert.html ? <div dangerouslySetInnerHTML={{ __html: alert.message }} /> : alert.message}
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
