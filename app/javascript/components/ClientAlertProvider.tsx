import classNames from "classnames";
import * as React from "react";

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

export const ClientAlert = ({ alert }: { alert: AlertPayload | null }) =>
  alert ? (
    <div
      key={alert.timestamp}
      role="alert"
      className={classNames(
        "bg-filled pointer-events-auto fixed top-4 left-1/2 z-[30] max-w-sm min-w-max -translate-x-1/2 px-4 py-2",
        alert.status,
        "animate-fade-in-down-out-up",
      )}
      dangerouslySetInnerHTML={alert.html ? { __html: alert.message } : undefined}
    >
      {!alert.html ? alert.message : null}
    </div>
  ) : null;
