import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { showAlert } from "$app/components/server-components/Alert";

type AdminUserChangeEmailProps = {
  user: User;
};

const AdminUserChangeEmail = ({ user }: AdminUserChangeEmailProps) => (
  <>
    <hr />
    <details>
      <summary>
        <h3>Change email</h3>
      </summary>
      <Form
        url={Routes.update_email_admin_user_path(user.id)}
        method="POST"
        confirmMessage="Are you sure you want to update this user's email address?"
        onSuccess={() => showAlert("Successfully updated email address.", "success")}
      >
        {(isLoading) => (
          <fieldset>
            <div className="grid grid-cols-[1fr_auto] gap-3">
              <input type="email" name="update_email[email_address]" placeholder={user.email} required />
              <button type="submit" className="button" disabled={isLoading}>
                {isLoading ? "Updating..." : "Update email"}
              </button>
            </div>
            <small>This will update the user's email to this new one!</small>
          </fieldset>
        )}
      </Form>
    </details>
  </>
);

export default AdminUserChangeEmail;
