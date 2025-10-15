import React from "react";

import AdminChangeEmailForm from "$app/components/Admin/Users/ChangeEmail/Form";
import type { User } from "$app/components/Admin/Users/User";

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
      <AdminChangeEmailForm user_id={user.id} current_email={user.email} />
    </details>
  </>
);

export default AdminUserChangeEmail;
