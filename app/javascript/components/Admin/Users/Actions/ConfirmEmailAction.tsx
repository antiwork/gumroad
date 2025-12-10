import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type ConfirmEmailActionProps = {
  user: User;
};

const ConfirmEmailAction = ({ user: { external_id } }: ConfirmEmailActionProps) => (
  <AdminAction
    label="Confirm Email"
    url={Routes.confirm_email_admin_user_path(external_id)}
    confirm_message={`Are you sure you want to confirm the email address for ${external_id}?`}
    success_message="Confirmed email."
    done="Confirmed email."
  />
);

export default ConfirmEmailAction;
