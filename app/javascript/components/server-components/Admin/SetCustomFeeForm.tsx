import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminSetCustomFeeForm = ({
  user_id,
  custom_fee_percent,
}: {
  user_id: number;
  custom_fee_percent: number | null;
}) => (
  <Form
    url={Routes.set_custom_fee_admin_user_path(user_id)}
    method="POST"
    confirmMessage={`Are you sure you want to update this user's custom fee?`}
    onSuccess={() => showAlert("Custom fee updated.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div className="input-with-button" style={{ alignItems: "start" }}>
          <input
            name="custom_fee_percent"
            type="number"
            inputMode="decimal"
            min="0"
            max="100"
            step="0.1"
            defaultValue={custom_fee_percent ?? ""}
            placeholder="Enter a custom fee percentage between 0 and 100. Submit blank to clear existing custom fee."
          />
          <button type="submit" className="button" disabled={isLoading} id="update-custom-fee">
            {isLoading ? "Submitting..." : "Submit"}
          </button>
        </div>
        <small>
          Note: Updated custom fee will apply to new direct (non-discover) sales of the user, but not to future charges
          of their existing memberships.
        </small>
      </fieldset>
    )}
  </Form>
);

export default register({ component: AdminSetCustomFeeForm, propParser: createCast() });
