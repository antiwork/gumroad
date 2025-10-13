import cx from "classnames";
import * as React from "react";

import { Icon } from "$app/components/Icons";

type AlertStatus = "success" | "error" | "info" | "warning" | "danger";

const ALERT_CONFIG = {
  success: {
    iconName: "solid-check-circle" as const,
    containerClasses: "border-success bg-success/20",
    iconClasses: "text-success",
  },
  danger: {
    iconName: "x-circle-fill" as const,
    containerClasses: "border-danger bg-danger/20",
    iconClasses: "text-danger",
  },
  warning: {
    iconName: "solid-shield-exclamation" as const,
    containerClasses: "border-warning bg-warning/20",
    iconClasses: "text-warning",
  },
  info: {
    iconName: "info-circle-fill" as const,
    containerClasses: "border-info bg-info/20",
    iconClasses: "text-info",
  },
} as const;

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

type AlertProps = {
  status: Exclude<AlertStatus, "error">;
  message: string;
  html?: boolean;
};

const Alert: React.FC<AlertProps> = ({ status, message, html }) => {
  const config = ALERT_CONFIG[status];

  return (
    <div className="flex items-center gap-3">
      <Icon name={config.iconName} className={cx("h-5 w-5 flex-shrink-0", config.iconClasses)} />
      {html ? <div dangerouslySetInnerHTML={{ __html: message }} /> : <div>{message}</div>}
    </div>
  );
};

export const ClientAlert = ({ alert, isVisible }: { alert: AlertPayload | null; isVisible: boolean }) => {
  if (!alert) return null;

  const status = alert.status === "error" ? "danger" : alert.status;
  const config = ALERT_CONFIG[status];

  return (
    <div
      role="alert"
      className={cx(
        "fixed top-4 left-1/2 z-[9999] -translate-x-1/2",
        "min-h-10 w-max max-w-[calc(100vw-2rem)] md:max-w-sm",
        "rounded border p-3",
        "transition-all delay-500 duration-300 ease-out",
        config.containerClasses,
        isVisible ? "pointer-events-auto translate-y-0 opacity-100" : "pointer-events-none -translate-y-16 opacity-0",
      )}
    >
      <Alert status={status} message={alert.message} html={alert.html ?? false} />
    </div>
  );
};
