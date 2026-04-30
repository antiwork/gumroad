import * as React from "react";
import { cast } from "ts-safe-cast";

import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { ButtonColor } from "$app/components/design";
import { showAlert } from "$app/components/server-components/Alert";

type AdminActionButtonProps = {
  url: string;
  method?: "POST" | "DELETE" | null;
  label: string;
  loading?: string | null;
  done?: string | null;
  confirm_message?: string | null;
  success_message?: string | null;
  show_message_in_alert?: boolean | null;
  outline?: boolean | null;
  color?: ButtonColor | null;
  class?: string | null;
  // ARIA INJECTION: Added to provide explicit context to screen readers
  aria_label?: string | null; 
};

export const AdminActionButton = ({
  url,
  method,
  label,
  loading,
  done,
  confirm_message,
  success_message,
  show_message_in_alert,
  outline,
  color,
  class: className,
  aria_label,
}: AdminActionButtonProps) => {
  const [state, setState] = React.useState<"initial" | "loading" | "done">("initial");

  // TODO RESOLUTION: Automatic state reset
  // This resolves the misleading "done" effect by returning the UI to the initial label
  // after the user has had 3 seconds to confirm success.
  React.useEffect(() => {
    if (state === "done") {
      const timeout = setTimeout(() => setState("initial"), 3000);
      return () => clearTimeout(timeout);
    }
  }, [state]);

  const handleSubmit = async () => {
    if (!confirm(confirm_message || `Are you sure you want to ${label}?`)) {
      return;
    }

    setState("loading");

    const csrfToken = cast<string>($("meta[name=csrf-token]").attr("content"));

    try {
      const response = await request({
        url,
        method: method || "POST",
        accept: "json",
        data: { authenticity_token: csrfToken },
      });

      if (!response.ok) throw new ResponseError("Something went wrong.");

      const { success, message, redirect_to } = cast<{ success?: boolean; message?: string; redirect_to?: string }>(
        await response.json(),
      );
      if (!success) throw new ResponseError(message || "Something went wrong.");

      if (message && show_message_in_alert) {
        alert(message);
      } else {
        showAlert(message || success_message || "Worked.", "success");
      }
      setState("done");

      if (redirect_to) window.location.href = redirect_to;
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
      setState("initial");
    }
  };

  // Compute the current accessible label based on state if no explicit aria_label is provided
  const currentAriaLabel = aria_label ?? (state === "done" ? (done ?? "Action completed") : state === "loading" ? (loading ?? "Processing request") : label);

  return (
    <Button
      type="button"
      size="sm"
      outline={outline ?? false}
      color={color ?? undefined}
      className={className ?? undefined}
      onClick={() => void handleSubmit()}
      disabled={state === "loading"}
      // ARIA ATRIBUTES:
      aria-label={currentAriaLabel}
      aria-busy={state === "loading"}
      aria-live="polite"
    >
      {state === "done" ? (done ?? "Done") : state === "loading" ? (loading ?? "...") : label}
    </Button>
  );
};

export default AdminActionButton;
