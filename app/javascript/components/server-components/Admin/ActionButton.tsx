import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { ButtonColor } from "$app/components/design";
import { showAlert } from "$app/components/server-components/Alert";

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
}: {
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
}) => {
  const [state, setState] = React.useState<"initial" | "loading" | "done">("initial");

  const handleSubmit = async () => {
    // eslint-disable-next-line no-alert
    if (!confirm(confirm_message || `Are you sure you want to ${label}?`)) {
      return;
    }

    setState("loading");

    try {
      const response = await request({
        url,
        method: method || "POST",
        accept: "json",
      });

      if (!response.ok) throw new ResponseError("Something went wrong.");

      const { success, message, redirect_to } = cast<{ success?: boolean; message?: string; redirect_to?: string }>(
        await response.json(),
      );
      if (!success) throw new ResponseError(message || "Something went wrong.");

      if (message && show_message_in_alert) {
        // eslint-disable-next-line no-alert
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

  return (
    <Button
      type="button"
      small
      outline={outline ?? false}
      color={color ?? undefined}
      className={className ?? undefined}
      onClick={() => void handleSubmit()}
      disabled={state === "loading"}
    >
      {state === "done" ? (done ?? "Done") : state === "loading" ? (loading ?? "...") : label}
    </Button>
  );
};

export default register({ component: AdminActionButton, propParser: createCast() });
