import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type MarkAsAdultActionProps = {
  user: User;
};

const MarkAsAdultAction = ({ user: { id, all_adult_products } }: MarkAsAdultActionProps) =>
  all_adult_products ? (
    <AdminAction
      label="Unmark as adult"
      url={Routes.toggle_adult_products_admin_user_path(id)}
      confirm_message={`Are you sure you want to unmark user ${id} as adult?`}
      done="Mark as adult"
      success_message="Unmarked as adult."
    />
  ) : (
    <AdminAction
      label="Mark as adult"
      url={Routes.toggle_adult_products_admin_user_path(id)}
      confirm_message={`Are you sure you want to mark user ${id} as adult?`}
      done="Unmark as adult"
      success_message="Marked as adult."
    />
  );

export default MarkAsAdultAction;
