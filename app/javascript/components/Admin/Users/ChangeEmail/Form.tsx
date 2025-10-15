import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

type AdminChangeEmailFormProps = {
  user_id: number;
  current_email: string | null;
};

const AdminChangeEmailForm = ({ user_id, current_email }: AdminChangeEmailFormProps) => (
  <Form
    url={Routes.update_email_admin_user_path(user_id)}
    method="POST"
    confirmMessage="Are you sure you want to update this user's email address?"
    onSuccess={() => showAlert("Successfully updated email address.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div className="grid grid-cols-[1fr_auto] gap-3">
          <input type="email" name="update_email[email_address]" placeholder={current_email ?? ""} required />
          <button type="submit" className="button" disabled={isLoading}>
            {isLoading ? "Updating..." : "Update email"}
          </button>
        </div>
        <small>This will update the user's email to this new one!</small>
      </fieldset>
    )}
  </Form>
);

export default AdminChangeEmailForm;
