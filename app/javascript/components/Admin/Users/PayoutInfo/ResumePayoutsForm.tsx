import * as React from "react";

import { Form } from "$app/components/Admin/Form";

const AdminResumePayoutsForm = ({
  user_id,
  payouts_paused_by,
  reason,
  onSuccess,
}: {
  user_id: number;
  payouts_paused_by: "stripe" | "admin" | "system" | "user" | null;
  reason: string | null;
  onSuccess: () => void;
}) => (
  <Form
    url={Routes.resume_admin_user_payouts_path(user_id)}
    method="POST"
    confirmMessage={`Are you sure you want to resume payouts for user ${user_id}?`}
    onSuccess={onSuccess}
  >
    {(isLoading) => (
      <fieldset>
        <div className="input-with-button !items-end">
          {payouts_paused_by === "admin" ? (
            <p>Payouts are currently paused by Gumroad admin. Reason: {reason}</p>
          ) : payouts_paused_by === "system" ? (
            <p>Payouts are currently automatically paused by the system. See comments below for details.</p>
          ) : payouts_paused_by === "stripe" ? (
            <p>Payouts are currently paused by Stripe because of pending verification requirements.</p>
          ) : (
            <div className="grid gap-2">
              {payouts_paused_by === "user" && <p>Payouts are currently paused by the creator.</p>}
            </div>
          )}
          <button type="submit" className="button" disabled={isLoading}>
            {isLoading ? "Resuming Payouts" : "Resume Payouts"}
          </button>
        </div>
      </fieldset>
    )}
  </Form>
);

export default AdminResumePayoutsForm;
