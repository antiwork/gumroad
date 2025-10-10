import classNames from "classnames";
import * as React from "react";

type AlertStatus = "success" | "error" | "info" | "warning" | "danger";

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

export const ClientAlert = ({ alert, isVisible }: { alert: AlertPayload | null; isVisible: boolean }) =>
  alert ? (
    <div
      role="alert"
      className={classNames("bg-filled fixed top-4 left-1/2 z-[30] max-w-sm min-w-max px-4 py-2", alert.status, {
        visible: isVisible,
        invisible: !isVisible,
        "-translate-x-1/2 translate-y-0 transition-all delay-500 duration-300 ease-out": isVisible,
        "-translate-x-1/2 translate-y-[-calc(100%+var(--spacer-4))] transition-all delay-500 duration-300 ease-out":
          !isVisible,
      })}
      dangerouslySetInnerHTML={alert.html ? { __html: alert.message } : undefined}
    >
      {!alert.html ? alert.message : null}
    </div>
  ) : null;
