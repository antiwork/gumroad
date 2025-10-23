import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

export const AdminChangeEmailForm = ({ user_id, current_email }: { user_id: number; current_email: string | null }) => (
  <Form
    url={Routes.update_email_admin_user_path(user_id)}
    method="POST"
    confirmMessage="Are you sure you want to update this user's email address?"
    onSuccess={() => showAlert("Successfully updated email address.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div style={{ display: "grid", gap: "var(--spacer-3)", gridTemplateColumns: "1fr auto" }}>
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

export default register({ component: AdminChangeEmailForm, propParser: createCast() });
