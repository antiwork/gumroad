import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type UndeleteActionProps = {
  user: User;
};

const UndeleteAction = ({ user: { id, deleted_at } }: UndeleteActionProps) =>
  deleted_at && (
    <AdminAction
      label="Undelete"
      url={Routes.enable_admin_user_path(id)}
      confirm_message={`Are you sure you want to undelete the account of user ${id}?`}
      done="Undeleted."
      success_message="Undeleted"
    />
  );

export default UndeleteAction;
