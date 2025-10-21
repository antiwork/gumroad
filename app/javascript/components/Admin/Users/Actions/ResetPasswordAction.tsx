import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type ResetPasswordActionProps = {
  user: User;
};

const ResetPasswordAction = ({ user: { id } }: ResetPasswordActionProps) => (
  <AdminAction
    label="Reset password"
    url={Routes.reset_password_admin_user_path(id)}
    confirm_message={`Are you sure you want to reset the password of user ${id}?`}
    loading="Resetting..."
    done="Password reset."
    show_message_in_alert
  />
);

export default ResetPasswordAction;
