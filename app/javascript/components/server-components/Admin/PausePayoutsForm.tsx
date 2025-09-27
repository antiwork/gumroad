import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminPausePayoutsForm = ({
  user_id,
  payouts_paused_by,
  reason,
}: {
  user_id: number;
  payouts_paused_by: "stripe" | "admin" | "system" | "user" | null;
  reason: string | null;
}) => {
  const admin_can_resume_payouts = payouts_paused_by && ["admin", "system", "stripe"].includes(payouts_paused_by);

  return (
    <Form
      url={
        admin_can_resume_payouts
          ? Routes.resume_admin_user_payouts_path(user_id)
          : Routes.pause_admin_user_payouts_path(user_id)
      }
      method="POST"
      confirmMessage={`Are you sure you want to ${admin_can_resume_payouts ? "resume" : "pause"} payouts for user ${user_id}?`}
      onSuccess={() => showAlert(admin_can_resume_payouts ? "Payouts resumed" : "Payouts paused", "success")}
    >
      {(isLoading) => (
        <fieldset>
          <div className="input-with-button" style={{ alignItems: "end" }}>
            {payouts_paused_by === "admin" ? (
              <p>Payouts are currently paused by Gumroad admin. Reason: {reason}</p>
            ) : payouts_paused_by === "system" ? (
              <p>Payouts are currently automatically paused by the system. See comments below for details.</p>
            ) : payouts_paused_by === "stripe" ? (
              <p>Payouts are currently paused by Stripe because of pending verification requirements.</p>
            ) : (
              <div className="grid gap-2">
                {payouts_paused_by === "user" && <p>Payouts are currently paused by the creator.</p>}
                <textarea
                  name="pause_payouts[reason]"
                  rows={2}
                  placeholder="Add a reason for pausing payouts. It'll be displayed to the user on their dashboard."
                />
              </div>
            )}
            <button type="submit" className="button" disabled={isLoading}>
              {isLoading
                ? admin_can_resume_payouts
                  ? "Resuming Payouts"
                  : "Pausing Payouts"
                : admin_can_resume_payouts
                  ? "Resume Payouts"
                  : "Pause Payouts"}
            </button>
          </div>
        </fieldset>
      )}
    </Form>
  );
};

export default register({ component: AdminPausePayoutsForm, propParser: createCast() });
