import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminCustomDirectFeeForm = ({
  user_id,
  current_percentage,
}: {
  user_id: number;
  current_percentage?: string | null;
}) => (
  <Form
    url={Routes.custom_direct_fee_admin_user_path(user_id)}
    method="POST"
    confirmMessage={`Are you sure you want to update the custom direct fee for user ${user_id}?`}
    onSuccess={() => showAlert("Custom direct fee updated.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div className="input-with-button" style={{ alignItems: "start" }}>
          <input
            name="custom_direct_fee[percentage]"
            type="number"
            min="0"
            max="100"
            step="0.01"
            defaultValue={current_percentage || ""}
            placeholder="Enter a custom direct fee percentage (0–100). Leave blank to remove."
          />
          <button type="submit" className="button" disabled={isLoading} id="update-custom-direct-fee">
            {isLoading ? "Submitting..." : "Submit"}
          </button>
        </div>
        <small>
          Changing the custom direct fee will apply to all future purchases <i>not retroactively.</i>
        </small>
      </fieldset>
    )}
  </Form>
);

export default register({ component: AdminCustomDirectFeeForm, propParser: createCast() });
