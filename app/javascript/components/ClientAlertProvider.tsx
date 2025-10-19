import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { Icon } from "$app/components/Icons";

type AlertStatus = "success" | "error" | "info" | "warning" | "danger";

export type AlertPayload = {
  message: string;
  status: AlertStatus;
  html?: boolean;
  timestamp?: number;
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

const ALERT_STYLES = {
  success: {
    icon: "solid-check-circle" as const,
    container: "border-green bg-green/20",
    iconColor: "text-green",
  },
  danger: {
    icon: "x-circle-fill" as const,
    container: "border-red bg-red/20",
    iconColor: "text-red",
  },
  warning: {
    icon: "solid-shield-exclamation" as const,
    container: "border-orange bg-orange/20",
    iconColor: "text-orange",
  },
  info: {
    icon: "info-circle-fill" as const,
    container: "border-purple bg-purple/20",
    iconColor: "text-purple",
  },
};

const ClientAlertContext = React.createContext<ClientAlertContextType | null>(null);

export const ClientAlertProvider = ({ children }: { children: React.ReactNode }) => {
  const [state, setState] = React.useState<AlertState>({
    alert: null,
    isVisible: false,
  });

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
    },
    [],
  );

  const hideAlert = React.useCallback(() => {
    setState({ alert: null, isVisible: false });
  }, []);

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

export const ClientAlert = ({ alert }: { alert: AlertPayload | null }) => {
  if (!alert) return null;

  const styles = ALERT_STYLES[alert.status === "error" ? "danger" : alert.status];

  return (
    <div
      key={alert.timestamp}
      role="alert"
      className={classNames(
        "pointer-events-auto fixed top-4 left-1/2 z-[30] -translate-x-1/2",
        "w-max max-w-[calc(100vw-2rem)] md:max-w-sm",
        "grid grid-cols-[auto_1fr] items-center gap-2 rounded border px-4 py-2",
        styles.container,
        "animate-fade-in-down-out-up",
      )}
    >
      <Icon name={styles.icon} className={classNames("min-h-[1lh] w-[1em]", styles.iconColor)} />
      <div dangerouslySetInnerHTML={alert.html ? { __html: alert.message } : undefined}>
        {!alert.html ? alert.message : null}
      </div>
    </div>
  );
};
