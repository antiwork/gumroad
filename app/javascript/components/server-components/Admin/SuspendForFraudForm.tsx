import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminSuspendForFraudForm = ({ user_id }: { user_id: number }) => (
  <Form
    url={Routes.suspend_for_fraud_admin_user_path(user_id)}
    method="POST"
    confirmMessage={`Are you sure you want to suspend user ${user_id} for fraud?`}
    onSuccess={() => showAlert("Suspended.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div className="input-with-button" style={{ alignItems: "start" }}>
          <textarea name="suspend_for_fraud[suspension_note]" rows={3} placeholder="Add suspension note (optional)" />
          <button type="submit" className="button" disabled={isLoading}>
            {isLoading ? "Submitting..." : "Submit"}
          </button>
        </div>
      </fieldset>
    )}
  </Form>
);

export default register({ component: AdminSuspendForFraudForm, propParser: createCast() });
