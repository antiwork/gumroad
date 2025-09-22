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

export const useClientAlert = () => {
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

  // Cleanup timer on unmount
  React.useEffect(() => clearTimer, []);

  return {
    alert: state.alert,
    isVisible: state.isVisible,
    showAlert,
    hideAlert,
  };
};

export const ClientAlert = ({ alert, isVisible }: { alert: AlertPayload | null; isVisible: boolean }) =>
  alert ? (
    <div
      role="alert"
      className={`bg-filled fixed left-1/2 top-4 min-w-max max-w-sm px-4 py-2 ${
        alert.status
      } ${isVisible ? "visible" : "invisible"}`}
      style={{
        transform: `translateX(-50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: "all 0.3s ease-out 0.5s",
        zIndex: "var(--z-index-tooltip)",
      }}
      dangerouslySetInnerHTML={alert.html ? { __html: alert.message } : undefined}
    >
      {!alert.html ? alert.message : null}
    </div>
  ) : null;
