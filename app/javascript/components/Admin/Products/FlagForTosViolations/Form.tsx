import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

type AdminSuspendForTosFormProps = {
  user_external_id: string;
  product_external_id: string;
  success_message: string;
  confirm_message: string;
  reasons: Record<string, string>;
  default_reason: string;
  onSuccess?: () => void;
};

export const AdminSuspendForTosForm = ({
  user_external_id,
  product_external_id,
  success_message,
  confirm_message,
  reasons,
  default_reason,
  onSuccess = () => {},
}: AdminSuspendForTosFormProps) => {
  const onFormSuccess = () => {
    showAlert(success_message, "success");
    onSuccess();
  };

  return (
    <Form
      url={Routes.admin_user_product_tos_violation_flags_path(user_external_id, product_external_id)}
      method="POST"
      confirmMessage={confirm_message}
      onSuccess={onFormSuccess}
      className="flex gap-2"
    >
      {(isLoading) => (
        <>
          <select name="suspend_tos[reason]" defaultValue={default_reason} className="flex-1">
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
};

export default AdminSuspendForTosForm;
