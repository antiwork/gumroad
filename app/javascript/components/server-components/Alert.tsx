import cx from "classnames";
import * as React from "react";
import { is } from "ts-safe-cast";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";

type AlertPayload = {
  message: string;
  status: "success" | "danger" | "info" | "warning" | "alert";
  html?: boolean;
};

const getAlertClasses = (status: string) => {
  const baseClasses =
    "fixed left-1/2 top-4 w-max max-w-[calc(100vw-2rem)] px-4 py-2 md:max-w-sm rounded flex items-center gap-3 font-semibold z-50 border-2";

  switch (status) {
    case "success":
      return `${baseClasses} bg-black text-gray-900 border-[#23a094]`;
    case "danger":
    case "alert":
      return `${baseClasses} bg-black text-gray-900 border-[#dc341e]`;
    case "warning":
      return `${baseClasses} bg-black text-gray-900 border-[#ffc900]`;
    case "info":
      return `${baseClasses} bg-black text-gray-900 border-[#90a8ed]`;
    default:
      return `${baseClasses} bg-black text-gray-900 border-gray-400`;
  }
};

// SVG icons: simple, white on color, black on info, visually matches your screenshots
const getAlertIcon = (status: string) => {
  const iconBaseClasses = "w-6 h-6 flex-shrink-0";
  switch (status) {
    case "success":
      return (
        <svg className={iconBaseClasses} fill="none" viewBox="0 0 24 24" stroke="#23a094" strokeWidth="2">
          <circle cx="12" cy="12" r="10" fill="#23a094" opacity="1" />
          <path strokeLinecap="round" strokeLinejoin="round" d="M6 13l4 4 8-8" stroke="black" />
        </svg>
      );
    case "danger":
      return (
        <svg className={iconBaseClasses} fill="none" viewBox="0 0 24 24" stroke="#dc431e" strokeWidth="2">
          <circle cx="12" cy="12" r="10" fill="#dc341e" opacity="1" />
          <path strokeLinecap="round" strokeLinejoin="round" d="M6 6l12 12M6 18L18 6" stroke="black" />
        </svg>
      );
    case "warning":
      return (
        <svg className={iconBaseClasses} fill="none" viewBox="0 0 24 24" stroke="#ffc900" strokeWidth="2">
          <circle cx="12" cy="12" r="10" fill="#ffc900" opacity="1" />
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 8v4m0 4h.01" stroke="black" />
        </svg>
      );
    case "info":
      return (
        <svg className={iconBaseClasses} fill="none" viewBox="0 0 24 24" stroke="#90a8ed" strokeWidth="2">
          <circle cx="12" cy="12" r="10" fill="#90a8ed" opacity="1" />
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 16v-4m0-4h.01" stroke="black" />
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
      className={cx(getAlertClasses(alert.status), {
        visible: isVisible,
        invisible: !isVisible,
      })}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: "all 0.3s cubic-bezier(0.4,0,0.2,1) 0.5s",
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
  status: "success" | "error" | "info" | "warning" | "alert",
  options: { html?: boolean } = { html: false },
) => {
  const mapStatus = (inputStatus: typeof status): "success" | "danger" | "info" | "warning" => {
    switch (inputStatus) {
      case "error":
      case "alert":
        return "danger";
      case "success":
        return "success";
      case "warning":
        return "warning";
      case "info":
        return "info";
      default:
        return "info"; // fallback
    }
  };

  window.postMessage(
    {
      type: ALERT_KEY,
      payload: {
        message,
        status: mapStatus(status),
        html: options.html,
      },
    },
    window.location.origin,
  );
};

export default Alert;
