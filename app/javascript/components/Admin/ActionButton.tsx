// TODO: the done effect is misleading when we show the reverse of the label
//! as it implies that when you click again to undo the action
//! it will show back the initial label when the undo action is done
//! but it keeps showing the done label that was initially set in the prop of this component

import * as React from "react";
import { cast } from "ts-safe-cast";

import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useClientAlert } from "$app/components/ClientAlertProvider";
import { ButtonColor } from "$app/components/design";

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
}: AdminActionButtonProps) => {
  const { showAlert } = useClientAlert();
  const [state, setState] = React.useState<"initial" | "loading" | "done">("initial");

  const handleSubmit = async () => {
    // eslint-disable-next-line no-alert
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

export default AdminActionButton;
