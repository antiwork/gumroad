import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminAddCreditForm = ({ user_id }: { user_id: number }) => (
  <Form
    url={Routes.add_credit_admin_user_path(user_id)}
    method="POST"
    confirmMessage="Are you sure you want to add credits?"
    onSuccess={() => showAlert("Successfully added credits.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div className="grid auto-cols-max grid-flow-col items-center gap-3" style={{ gridTemplateColumns: "1fr" }}>
          <div className="input">
            <span className="pill">$</span>
            <input type="text" name="credit[credit_amount]" placeholder="10.25" inputMode="decimal" required />
          </div>
          <button type="submit" className="button" disabled={isLoading}>
            {isLoading ? "Saving..." : "Add credits"}
          </button>
        </div>
        <small>Subtract credits by providing a negative value</small>
      </fieldset>
    )}
  </Form>
);

export default register({ component: AdminAddCreditForm, propParser: createCast() });
