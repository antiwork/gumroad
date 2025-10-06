import * as React from "react";
import { is } from "ts-safe-cast";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useRunOnce } from "$app/components/useRunOnce";

const ALERT_KEY = "alert";

type AlertStatus = "success" | "danger" | "info" | "warning" | "alert";
type InputStatus = "success" | "error" | "info" | "warning" | "alert";

export type AlertPayload = {
  message: string;
  status: AlertStatus;
  html?: boolean;
};

interface StatusConfig {
  borderColor: string;
  iconColor: string;
  bgLight: string;
  bgDark: string;
}

const STATUS_CONFIG: Record<AlertStatus, StatusConfig> = {
  success: {
    borderColor: "#23a094",
    iconColor: "#23a094",
    bgLight: "rgba(35, 160, 148, 0.2)",
    bgDark: "rgba(35, 160, 148, 0.3)",
  },
  danger: {
    borderColor: "#dc341e",
    iconColor: "#dc341e",
    bgLight: "rgba(220, 52, 30, 0.2)",
    bgDark: "rgba(220, 52, 30, 0.3)",
  },
  warning: {
    borderColor: "#ffc900",
    iconColor: "#ffc900",
    bgLight: "rgba(255, 201, 0, 0.2)",
    bgDark: "rgba(255, 201, 0, 0.3)",
  },
  info: {
    borderColor: "#90a8ed",
    iconColor: "#90a8ed",
    bgLight: "rgba(144, 168, 237, 0.2)",
    bgDark: "rgba(144, 168, 237, 0.3)",
  },
  alert: {
    borderColor: "#dc341e",
    iconColor: "#dc341e",
    bgLight: "rgba(220, 52, 30, 0.2)",
    bgDark: "rgba(220, 52, 30, 0.3)",
  },
} as const;

const getStatusConfig = (status: string): StatusConfig => {
  const config = STATUS_CONFIG[status as AlertStatus];
  return config || STATUS_CONFIG.info;
};

const AlertStyles: React.FC = () => (
  <style
    dangerouslySetInnerHTML={{
      __html: `
      .alert-container {
        text-color: #000000 !important;
        stroke-color: #000000 !important;
      }

      .alert-container.dark-mode {
        text-color: #ffffff !important;
        stroke-color: #ffffff !important;
      }

      .alert-container * {
        text-color: inherit !important;
      }

      .alert-container .prose,
      .alert-container .prose * {
        text-color: inherit !important;
      }
    `,
    }}
  />
);

const getAlertClasses = (isDark: boolean): string => {
  return [
    "alert-container",
    isDark ? "dark-mode" : "",

    "flex items-center",

    "px-2 py-1 gap-1",

    "border rounded",

    "fixed left-1/2 top-4 -translate-x-1/2",

    "w-max max-w-[calc(100vw-2rem)] md:max-w-sm",

    "text-s font-normal leading-tight",

    "z-50",

    "transition-all duration-300 ease-out",
  ]
    .filter(Boolean)
    .join(" ");
};

interface AlertIconProps {
  status: string;
  isDark: boolean;
}

const AlertIcon: React.FC<AlertIconProps> = ({ status, isDark }) => {
  const config = getStatusConfig(status);
  const strokeColor = isDark ? "#ffffff" : "#000000";

  const iconProps = {
    className: "w-8 h-10 flex-shrink-0",
    viewBox: "0 0 24 24",
    fill: "none",
    "aria-hidden": true,
    minHeight: "max(1lh, 1rem)",
    width: "1lh",
  } as const;

  switch (status) {
    case "success":
      return (
        <svg {...iconProps}>
          <circle cx="12" cy="12" r="7" fill={config.iconColor} />
          <path
            d="M9 12l2 2 3.5-3.5"
            stroke={strokeColor}
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      );

    case "danger":
    case "alert":
      return (
        <svg {...iconProps}>
          <circle cx="12" cy="12" r="7" fill={config.iconColor} />
          <path
            d="M9 12l2 2 3.5-3.5"
            stroke={strokeColor}
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      );

    case "warning":
      return (
        <svg {...iconProps}>
          <circle cx="12" cy="12" r="17" fill={config.iconColor} />
          <path
            d="M9 12l2 2 3.5-3.5"
            stroke={strokeColor}
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      );

    case "info":
      return (
        <svg {...iconProps}>
          <circle cx="12" cy="12" r="7" fill={config.iconColor} />
          <path
            d="M9 12l2 2 3.5-3.5"
            stroke={strokeColor}
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      );

    default:
      return (
        <svg {...iconProps}>
          <circle cx="12" cy="12" r="7" fill={STATUS_CONFIG.info.iconColor} />
          <path
            d="M9 12l2 2 3.5-3.5"
            stroke={strokeColor}
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      );
  }
};

const useDarkMode = (): boolean => {
  const [isDark, setIsDark] = React.useState<boolean>(() => {
    if (typeof window === "undefined") return false;

    try {
      const hasSystemDark = window.matchMedia?.("(prefers-color-scheme: dark)")?.matches ?? false;
      const hasManualDark = document.documentElement.classList.contains("dark");
      return hasSystemDark || hasManualDark;
    } catch {
      return false;
    }
  });

  React.useEffect(() => {
    if (typeof window === "undefined") return;

    try {
      const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");

      const updateDarkMode = (): void => {
        try {
          const systemDark = mediaQuery.matches;
          const manualDark = document.documentElement.classList.contains("dark");
          setIsDark(systemDark || manualDark);
        } catch {}
      };

      if (mediaQuery.addEventListener) {
        mediaQuery.addEventListener("change", updateDarkMode);
      } else {
        mediaQuery.addListener(updateDarkMode);
      }

      const observer = new MutationObserver(updateDarkMode);
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["class"],
      });

      return () => {
        try {
          if (mediaQuery.removeEventListener) {
            mediaQuery.removeEventListener("change", updateDarkMode);
          } else {
            mediaQuery.removeListener(updateDarkMode);
          }
          observer.disconnect();
        } catch {}
      };
    } catch {
      return;
    }
  }, []);

  return isDark;
};

interface AlertProps {
  initial: AlertPayload | null;
}

const Alert: React.FC<AlertProps> = ({ initial }) => {
  const [alert, setAlert] = React.useState<AlertPayload | null>(initial);
  const [isVisible, setIsVisible] = React.useState<boolean>(!!initial);
  const timerRef = React.useRef<number | null>(null);
  const isDark = useDarkMode();

  const clearTimer = React.useCallback((): void => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const startTimer = React.useCallback((): void => {
    clearTimer();
    timerRef.current = window.setTimeout(() => {
      setIsVisible(false);
    }, 5000);
  }, [clearTimer]);

  useGlobalEventListener("message", (event: MessageEvent) => {
    if (event.origin !== window.location.origin) return;

    try {
      if (is<{ type: string; payload: AlertPayload }>(event.data) && event.data.type === ALERT_KEY) {
        const newAlert = event.data.payload;

        if (newAlert && typeof newAlert.message === "string" && typeof newAlert.status === "string") {
          setAlert(newAlert);
          setIsVisible(true);
          startTimer();
        }
      }
    } catch {}
  });

  useRunOnce(() => {
    if (initial) {
      startTimer();
    }
  });

  React.useEffect(() => {
    if (!isVisible && alert) {
      const cleanup = setTimeout(() => {
        setAlert(null);
      }, 300);

      return () => clearTimeout(cleanup);
    }
  }, [isVisible, alert]);

  if (!alert) return null;

  const config = getStatusConfig(alert.status);

  const alertStyles: React.CSSProperties = {
    backgroundColor: isDark ? config.bgDark : config.bgLight,
    borderColor: config.borderColor,
    transform: isVisible ? "translateX(-50%) translateY(0)" : "translateX(-50%) translateY(-100%)",
    opacity: isVisible ? 1 : 0,
  };

  return (
    <>
      <AlertStyles />

      <div
        role="alert"
        aria-live="assertive"
        aria-atomic="true"
        className={getAlertClasses(isDark)}
        style={alertStyles}
      >
        <AlertIcon status={alert.status} isDark={isDark} />

        <div className="min-w-0 break-words">
          {alert.html ? <div dangerouslySetInnerHTML={{ __html: alert.message }} /> : alert.message}
        </div>
      </div>
    </>
  );
};

const mapStatus = (inputStatus: InputStatus): AlertStatus => {
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
      return "info";
  }
};

export const showAlert = (message: string, status: InputStatus, options: { html?: boolean } = {}): void => {
  try {
    if (typeof window === "undefined") return;
    if (!message || typeof message !== "string") return;

    window.postMessage(
      {
        type: ALERT_KEY,
        payload: {
          message,
          status: mapStatus(status),
          html: options.html ?? false,
        } satisfies AlertPayload,
      },
      window.location.origin,
    );
  } catch {}
};

export default Alert;
