import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type VerifyActionProps = {
  user: User;
};

const VerifyAction = ({ user: { id, verified } }: VerifyActionProps) =>
  verified ? (
    <AdminAction
      label="Unverify"
      url={Routes.verify_admin_user_path(id)}
      confirm_message={`Are you sure you want to unverify user ${id}?`}
      done="Verify"
      success_message="Unverified."
    />
  ) : (
    <AdminAction
      label="Verify"
      url={Routes.verify_admin_user_path(id)}
      confirm_message={`Are you sure you want to verify user ${id}?`}
      done="Unverify"
      success_message="Verified."
    />
  );

export default VerifyAction;
