import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const MassTransferPurchasesForm = ({ user_id }: { user_id: number }) => (
  <Form
    url={Routes.mass_transfer_purchases_admin_user_path(user_id)}
    method="POST"
    confirmMessage="Are you sure you want to Mass Transfer purchases for this user?"
    onSuccess={() => showAlert("Successfully transferred purchases.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div style={{ display: "grid", gap: "var(--spacer-3)", gridTemplateColumns: "1fr auto" }}>
          <input type="email" name="mass_transfer_purchases[new_email]" placeholder="New email" required />
          <button type="submit" className="button" disabled={isLoading}>
            {isLoading ? "Transferring..." : "Transfer"}
          </button>
        </div>
        <small>Are you sure you want to Mass Transfer purchases for this user?</small>
      </fieldset>
    )}
  </Form>
);

export default register({ component: MassTransferPurchasesForm, propParser: createCast() });
