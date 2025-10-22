import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminSuspendForTosForm = ({
  product_id,
  success_message,
  confirm_message,
  reasons,
  default_reason,
}: {
  product_id: number;
  success_message: string;
  confirm_message: string;
  reasons: Record<string, string>;
  default_reason: string;
}) => (
  <Form
    url={Routes.flag_seller_for_tos_violation_admin_link_path(product_id)}
    method="POST"
    confirmMessage={confirm_message}
    onSuccess={() => showAlert(success_message, "success")}
    className="input-with-button"
  >
    {(isLoading) => (
      <>
        <select name="suspend_tos[reason]" defaultValue={default_reason}>
          {Object.entries(reasons).map(([name, value]) => (
            <option key={value} value={value}>
              {name}
            </option>
          ))}
        </select>
        <button type="submit" className="button" disabled={isLoading}>
          {isLoading ? "Suspending..." : "Submit"}
        </button>
      </>
    )}
  </Form>
);

export default register({ component: AdminSuspendForTosForm, propParser: createCast() });
