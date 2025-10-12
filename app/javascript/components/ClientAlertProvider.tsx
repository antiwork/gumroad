import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

type AlertStatus = "success" | "error" | "info" | "warning" | "danger";

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

type AlertPayload = {
  message: string;
  status: AlertStatus;
  html?: boolean;
};

type AlertState = {
  alert: AlertPayload | null;
  isVisible: boolean;
};

type ClientAlertContextType = {
  alert: AlertPayload | null;
  isVisible: boolean;
  showAlert: (message: string, status: AlertStatus, options?: { html?: boolean }) => void;
  hideAlert: () => void;
};

const ClientAlertContext = React.createContext<ClientAlertContextType | null>(null);

export const ClientAlertProvider = ({ children }: { children: React.ReactNode }) => {
  const [state, setState] = React.useState<AlertState>({
    alert: null,
    isVisible: false,
  });

  const timerRef = React.useRef<number | null>(null);

  const clearTimer = () => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  };

  const startTimer = () => {
    clearTimer();
    timerRef.current = window.setTimeout(() => {
      setState((prev) => ({ ...prev, isVisible: false }));
    }, 5000);
  };

  const showAlert = React.useCallback(
    (message: string, status: AlertStatus, options: { html?: boolean } = { html: false }) => {
      const newAlert: AlertPayload = {
        message,
        status: status === "error" ? "danger" : status,
        html: options.html ?? false,
      };

      setState({
        alert: newAlert,
        isVisible: true,
      });

      startTimer();
    },
    [],
  );

  const hideAlert = React.useCallback(() => {
    clearTimer();
    setState((prev) => ({ ...prev, isVisible: false }));
  }, []);

  React.useEffect(() => clearTimer, []);

  const value = React.useMemo(
    () => ({
      alert: state.alert,
      isVisible: state.isVisible,
      showAlert,
      hideAlert,
    }),
    [state.alert, state.isVisible, showAlert, hideAlert],
  );

  return <ClientAlertContext.Provider value={value}>{children}</ClientAlertContext.Provider>;
};

export const useClientAlert = () => {
  const context = React.useContext(ClientAlertContext);
  if (!context) {
    throw new Error("useClientAlert must be used within a ClientAlertProvider");
  }
  return context;
};

export const ClientAlert = ({ alert, isVisible }: { alert: AlertPayload | null; isVisible: boolean }) => {
  if (!alert) return null;

  const status = alert.status === "error" ? "danger" : alert.status;

  return (
    <div
      role="alert"
      className={cx(
        "fixed top-4 left-1/2 z-[9999] -translate-x-1/2",
        "min-h-10 w-max max-w-[calc(100vw-2rem)] md:max-w-sm",
        "flex items-center gap-3 rounded border p-3",
        "transition-all delay-500 duration-300 ease-out",
        {
          "border-[rgb(var(--success))] bg-[rgb(var(--success)/20%)]": status === "success",
          "border-[rgb(var(--danger))] bg-[rgb(var(--danger)/20%)]": status === "danger",
          "border-[rgb(var(--warning))] bg-[rgb(var(--warning)/20%)]": status === "warning",
          "border-[rgb(var(--info))] bg-[rgb(var(--info)/20%)]": status === "info",
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
              status === "success",
            "bg-[rgb(var(--danger))] [mask-image:var(--danger-icon)] [-webkit-mask-image:var(--danger-icon)]":
              status === "danger",
            "bg-[rgb(var(--warning))] [mask-image:var(--warning-icon)] [-webkit-mask-image:var(--warning-icon)]":
              status === "warning",
            "bg-[rgb(var(--info))] [mask-image:var(--info-icon)] [-webkit-mask-image:var(--info-icon)]":
              status === "info",
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
