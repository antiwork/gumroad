import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import type { User } from "$app/components/Admin/Users/User";

type RefundBalanceActionProps = {
  user: User;
};

const RefundBalanceAction = ({ user }: RefundBalanceActionProps) =>
  user.suspended &&
  user.unpaid_balance_cents > 0 && (
    <AdminAction
      label="Refund balance"
      url={Routes.refund_balance_admin_user_path(user.id)}
      confirm_message={`Are you sure you want to refund user ${user.id}'s not paid out purchases!?`}
      done="Refunded."
      success_message="Refunded"
    />
  );

export default RefundBalanceAction;
