// TODO: the done effect is misleading when we show the reverse of the label
//! as it implies that when you click again to undo the action
//! it will show back the initial label when the undo action is done
//! but it keeps showing the done label that was initially set in the prop of this component

import * as React from "react";
import typia from "typia";

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
  // When set, a text prompt is shown after the confirm dialog and the entered value is
  // sent to the server under `prompt_field_name`. Cancelling the prompt aborts the action.
  // With `prompt_required`, an empty value also aborts (with an error alert); otherwise an
  // empty value just omits the field.
  prompt_message?: string | null;
  prompt_field_name?: string | null;
  prompt_required?: boolean | null;
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
  prompt_message,
  prompt_field_name,
  prompt_required,
}: AdminActionButtonProps) => {
  const [state, setState] = React.useState<"initial" | "loading" | "done">("initial");

  const handleSubmit = async () => {
    // eslint-disable-next-line no-alert
    if (!confirm(confirm_message || `Are you sure you want to ${label}?`)) {
      return;
    }

    const data: Record<string, string> = {};
    if (prompt_message && prompt_field_name) {
      // eslint-disable-next-line no-alert
      const promptValue = prompt(prompt_message);
      // Cancelling the prompt cancels the whole action.
      if (promptValue === null) return;
      if (promptValue.trim() !== "") {
        data[prompt_field_name] = promptValue.trim();
      } else if (prompt_required) {
        // A required prompt (e.g. the refund reason emailed to the creator) can't be blank.
        showAlert("This action requires a reason.", "error");
        return;
      }
    }

    setState("loading");

    const csrfToken = typia.assert<string>(document.querySelector("meta[name=csrf-token]")?.getAttribute("content"));

    try {
      const response = await request({
        url,
        method: method || "POST",
        accept: "json",
        data: { ...data, authenticity_token: csrfToken },
      });

      if (!response.ok) throw new ResponseError("Something went wrong.");

      const { success, message, redirect_to } = typia.assert<{
        success?: boolean;
        message?: string;
        redirect_to?: string;
      }>(await response.json());
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
      size="sm"
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
