import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

type AlertStatus = "success" | "error" | "info" | "warning" | "danger";

const icons = require.context("$assets/images/icons/");

const ALERT_CONFIG = {
  success: {
    icon: cast(icons("./solid-check-circle.svg")),
    borderColor: "rgb(var(--success))",
    backgroundColor: "rgb(var(--success) / 20%)",
    iconColor: "rgb(var(--success))",
  },
  danger: {
    icon: cast(icons("./x-circle-fill.svg")),
    borderColor: "rgb(var(--danger))",
    backgroundColor: "rgb(var(--danger) / 20%)",
    iconColor: "rgb(var(--danger))",
  },
  warning: {
    icon: cast(icons("./solid-shield-exclamation.svg")),
    borderColor: "rgb(var(--warning))",
    backgroundColor: "rgb(var(--warning) / 20%)",
    iconColor: "rgb(var(--warning))",
  },
  info: {
    icon: cast(icons("./info-circle-fill.svg")),
    borderColor: "rgb(var(--info))",
    backgroundColor: "rgb(var(--info) / 20%)",
    iconColor: "rgb(var(--info))",
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
  const config = ALERT_CONFIG[status as keyof typeof ALERT_CONFIG];

  return (
    <div
      role="alert"
      className={cx(
        "fixed top-4 left-1/2 z-[9999]",
        "min-h-10 w-max max-w-[calc(100vw-2rem)] md:max-w-sm",
        "flex items-center gap-3 rounded border p-3",
        "transition-all delay-500 duration-300 ease-out",
        isVisible ? "pointer-events-auto opacity-100" : "pointer-events-none opacity-0",
      )}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? "0" : "-4rem"})`,
        borderColor: config.borderColor,
        backgroundColor: config.backgroundColor,
      }}
    >
      <div
        className="h-5 w-5 flex-shrink-0"
        style={{
          backgroundColor: config.iconColor,
          maskImage: `url(${config.icon})`,
          maskPosition: "center",
          maskSize: "contain",
          maskRepeat: "no-repeat",
          WebkitMaskImage: `url(${config.icon})`,
          WebkitMaskPosition: "center",
          WebkitMaskSize: "contain",
          WebkitMaskRepeat: "no-repeat",
        }}
      />
      {alert.html ? <div dangerouslySetInnerHTML={{ __html: alert.message }} /> : <div>{alert.message}</div>}
    </div>
  );
};
